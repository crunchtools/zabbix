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
