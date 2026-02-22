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
