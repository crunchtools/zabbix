FROM quay.io/crunchtools/ubi10-httpd-php-postgres

# Copy config files, scripts, and systemd units into the image
COPY rootfs/ /

# Add EPEL 10 for fping (required by zabbix-server-pgsql)
# Install Zabbix packages and additional PHP extensions
# Replace libcurl-minimal with full libcurl (UBI 10 ships libcurl-minimal which
# strips PSL support — Zabbix Script items fail HTTPS requests without it)
RUN --mount=type=secret,id=RHSM_ACTIVATION_KEY \
    --mount=type=secret,id=RHSM_ORG_ID \
    subscription-manager register \
      --activationkey="$(cat /run/secrets/RHSM_ACTIVATION_KEY)" \
      --org="$(cat /run/secrets/RHSM_ORG_ID)" \
    && dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm \
    && dnf install -y \
      glibc-langpack-en \
      php-bcmath \
      php-ldap \
      fping \
      zabbix-server-pgsql \
      zabbix-web-pgsql \
      zabbix-apache-conf \
      zabbix-sql-scripts \
    && dnf swap -y libcurl-minimal libcurl \
    && dnf clean all \
    && subscription-manager unregister

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

# Enable Zabbix services (postgresql and postgres-prep inherited from parent)
# zabbix-pg-prep adds Alpine UID migration on top of parent's postgres-prep
RUN systemctl enable zabbix-server zabbix-pg-prep zabbix-db-setup

ENTRYPOINT ["/sbin/init"]
