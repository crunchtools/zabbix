FROM quay.io/crunchtools/ubi10-httpd-php

# Register with RHSM to access full RHEL repos during build
ARG RHSM_ACTIVATION_KEY
ARG RHSM_ORG_ID
RUN if [ -n "$RHSM_ACTIVATION_KEY" ] && [ -n "$RHSM_ORG_ID" ]; then \
        subscription-manager register --activationkey="$RHSM_ACTIVATION_KEY" --org="$RHSM_ORG_ID"; \
    fi

# Add Zabbix 7.0 repo
RUN cat > /etc/yum.repos.d/zabbix.repo <<'EOF'
[zabbix]
name=Zabbix Official Repository
baseurl=https://repo.zabbix.com/zabbix/7.0/rhel/10/x86_64/
enabled=1
gpgcheck=1
gpgkey=https://repo.zabbix.com/RPM-GPG-KEY-ZABBIX-B5333005
EOF

# Add EPEL 10 for fping (required by zabbix-server-pgsql)
RUN dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm

# Install PostgreSQL and Zabbix packages
RUN dnf install -y \
    postgresql-server \
    glibc-langpack-en \
    php-pgsql \
    php-bcmath \
    php-ldap \
    fping \
    zabbix-server-pgsql \
    zabbix-web-pgsql \
    zabbix-apache-conf \
    zabbix-sql-scripts \
    && dnf clean all

# Replace libcurl-minimal with full libcurl
# UBI 10 ships libcurl-minimal, which strips out features like PSL (public
# suffix list) support. Zabbix's JavaScript HttpRequest engine uses libcurl
# internally for Script items — with the minimal package, HTTPS requests to
# external APIs (like CloudFlare) silently fail with timeouts.
RUN dnf swap -y libcurl-minimal libcurl && dnf clean all

# Unregister from RHSM to avoid leaking entitlements in the image
RUN subscription-manager unregister 2>/dev/null || true

# Serve Zabbix at / instead of /zabbix, remove default welcome page
RUN sed -i 's|Alias /zabbix /usr/share/zabbix|Alias / /usr/share/zabbix/|' /etc/httpd/conf.d/zabbix.conf && \
    rm -f /etc/httpd/conf.d/welcome.conf

# Zabbix server config - use local socket connection
RUN sed -i \
    -e 's/^# DBHost=.*/DBHost=/' \
    -e 's/^# DBName=.*/DBName=zabbix/' \
    -e 's/^# DBUser=.*/DBUser=zabbix/' \
    -e 's/^# DBPassword=.*/DBPassword=changeme/' \
    -e 's/^# Timeout=.*/Timeout=3/' \
    /etc/zabbix/zabbix_server.conf

# Zabbix web config
RUN cat > /etc/zabbix/web/zabbix.conf.php <<'EOPHP'
<?php
$DB['TYPE']             = 'POSTGRESQL';
$DB['SERVER']           = '';
$DB['PORT']             = '0';
$DB['DATABASE']         = 'zabbix';
$DB['USER']             = 'zabbix';
$DB['PASSWORD']         = 'changeme';
$DB['SCHEMA']           = '';
$DB['ENCRYPTION']       = false;
$DB['KEY_FILE']         = '';
$DB['CERT_FILE']        = '';
$DB['CA_FILE']          = '';
$DB['VERIFY_HOST']      = false;
$DB['CIPHER_LIST']      = '';
$DB['VAULT_URL']        = '';
$DB['VAULT_DB_PATH']    = '';
$DB['VAULT_TOKEN']      = '';
$DB['DOUBLE_IEEE754']   = true;
$ZBX_SERVER             = 'localhost';
$ZBX_SERVER_PORT        = '10051';
$ZBX_SERVER_NAME        = 'zabbix.example.com';
$IMAGE_FORMAT_DEFAULT   = IMAGE_FORMAT_PNG;
EOPHP

# Pre-postgres script: fix ownership and init if needed (runs before postgresql.service)
RUN cat > /usr/local/bin/zabbix-pg-prep.sh <<'EOSH'
#!/bin/bash
set -e

PGDATA="/var/lib/pgsql/data"

# Fix ownership - Alpine postgres used UID 70, RHEL uses UID 26
if [ -d "$PGDATA" ] && [ "$(stat -c %u "$PGDATA")" != "26" ]; then
    echo "zabbix-pg-prep: Fixing PostgreSQL data ownership (Alpine UID 70 -> RHEL UID 26)..."
    chown -R postgres:postgres "$PGDATA"
fi

# If PGDATA is empty, initialize it
if [ ! -f "$PGDATA/PG_VERSION" ]; then
    echo "zabbix-pg-prep: Initializing PostgreSQL database..."
    postgresql-setup --initdb
    # Set trust auth for local connections
    cat > "$PGDATA/pg_hba.conf" <<'EOHBA'
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
EOHBA
    chown postgres:postgres "$PGDATA/pg_hba.conf"
fi

echo "zabbix-pg-prep: Done."
EOSH
RUN chmod +x /usr/local/bin/zabbix-pg-prep.sh

# Post-postgres script: create DB user/schema after postgres is running
RUN cat > /usr/local/bin/zabbix-db-setup.sh <<'EOSH'
#!/bin/bash

PGDATA="/var/lib/pgsql/data"
MARKER="$PGDATA/.zabbix_schema_imported"

# Ensure postgres superuser role exists (Alpine creates zabbix role but not postgres)
# Wait for postgres to accept connections first
for i in $(seq 1 30); do
    if su - postgres -c "psql -U zabbix -d zabbix -c 'SELECT 1'" >/dev/null 2>&1 || \
       su - postgres -c "psql -c 'SELECT 1'" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# Create postgres superuser role if it doesn't exist (needed for RHEL pg tooling)
su - postgres -c "psql -U zabbix -d zabbix -tc \"SELECT 1 FROM pg_roles WHERE rolname='postgres'\"" 2>/dev/null | grep -q 1 || \
    su - postgres -c "psql -U zabbix -d zabbix -c \"CREATE ROLE postgres WITH SUPERUSER LOGIN\"" 2>/dev/null || true

# Create zabbix user and database if they don't exist
su - postgres -c "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='zabbix'\"" | grep -q 1 || \
    su - postgres -c "createuser zabbix" || true
su - postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname='zabbix'\"" | grep -q 1 || \
    su - postgres -c "createdb -O zabbix zabbix" || true

# Import schema only on fresh installs (no marker and no existing tables)
if [ ! -f "$MARKER" ]; then
    TABLE_COUNT=$(su - postgres -c "psql -t -d zabbix -c \"SELECT count(*) FROM information_schema.tables WHERE table_schema='public'\"" 2>/dev/null | tr -d ' ')
    if [ "$TABLE_COUNT" -eq 0 ] 2>/dev/null; then
        echo "zabbix-db-setup: Importing Zabbix schema..."
        zcat /usr/share/zabbix-sql-scripts/postgresql/server.sql.gz | su - postgres -c "psql -d zabbix"
    fi
    touch "$MARKER"
fi

echo "zabbix-db-setup: Done."
EOSH
RUN chmod +x /usr/local/bin/zabbix-db-setup.sh

# Systemd unit: pre-postgres prep (ownership fix, initdb)
RUN cat > /etc/systemd/system/zabbix-pg-prep.service <<'EOF'
[Unit]
Description=Zabbix PostgreSQL data preparation
After=local-fs.target
Before=postgresql.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zabbix-pg-prep.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Systemd unit: post-postgres DB setup (user, schema)
RUN cat > /etc/systemd/system/zabbix-db-setup.service <<'EOF'
[Unit]
Description=Zabbix DB user and schema setup
After=postgresql.service
Before=zabbix-server.service
Requires=postgresql.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zabbix-db-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable services, disable mariadb from base image
RUN systemctl enable postgresql zabbix-server zabbix-pg-prep zabbix-db-setup && \
    systemctl disable mariadb 2>/dev/null || true

ENTRYPOINT ["/sbin/init"]
