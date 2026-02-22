FROM quay.io/crunchtools/ubi10-httpd-php

# Register with RHSM to access full RHEL repos during build
ARG RHSM_ACTIVATION_KEY
ARG RHSM_ORG_ID
RUN if [ -n "$RHSM_ACTIVATION_KEY" ] && [ -n "$RHSM_ORG_ID" ]; then \
        subscription-manager register --activationkey="$RHSM_ACTIVATION_KEY" --org="$RHSM_ORG_ID"; \
    fi

# Copy config files, scripts, and systemd units into the image
COPY rootfs/ /

# Add EPEL 10 for fping (required by zabbix-server-pgsql)
# Install PostgreSQL and Zabbix packages
# Replace libcurl-minimal with full libcurl (UBI 10 ships libcurl-minimal which
# strips PSL support — Zabbix Script items fail HTTPS requests without it)
RUN dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm && \
    dnf install -y \
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
    && dnf swap -y libcurl-minimal libcurl \
    && dnf clean all

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

# Make scripts executable
RUN chmod +x /usr/local/bin/zabbix-pg-prep.sh /usr/local/bin/zabbix-db-setup.sh

# Enable services, disable mariadb from base image
RUN systemctl enable postgresql zabbix-server zabbix-pg-prep zabbix-db-setup && \
    systemctl disable mariadb 2>/dev/null || true

ENTRYPOINT ["/sbin/init"]
