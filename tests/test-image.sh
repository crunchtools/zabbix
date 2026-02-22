#!/bin/bash
# Test suite for Zabbix 7.0 all-in-one container image
# Usage: ./tests/test-image.sh [--static|--runtime|--all] <image:tag>
set -euo pipefail

PASS=0
FAIL=0
MODE="all"
IMAGE=""

# Auto-detect container runtime (prefer podman, fall back to docker)
if command -v podman &>/dev/null; then
    RUNTIME="podman"
elif command -v docker &>/dev/null; then
    RUNTIME="docker"
else
    echo "ERROR: Neither podman nor docker found"
    exit 1
fi

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

check() {
    local desc="$1"; shift
    if eval "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc"
    fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --static)  MODE="static";  shift ;;
        --runtime) MODE="runtime"; shift ;;
        --all)     MODE="all";     shift ;;
        *)         IMAGE="$1";     shift ;;
    esac
done

if [[ -z "$IMAGE" ]]; then
    echo "Usage: $0 [--static|--runtime|--all] <image:tag>"
    exit 1
fi

# Helper: run a command inside the image (no systemd, just exec)
run_in() {
    $RUNTIME run --rm --entrypoint /bin/sh "$IMAGE" -c "$*"
}

# =============================================================================
# STATIC TESTS - verify image contents without starting systemd
# =============================================================================
run_static_tests() {
    echo ""
    echo "=== Static Tests ==="

    echo ""
    echo "--- Package Installation ---"
    check "postgresql-server is installed" \
        run_in rpm -q postgresql-server
    check "zabbix-server-pgsql is installed" \
        run_in rpm -q zabbix-server-pgsql
    check "zabbix-web-pgsql is installed" \
        run_in rpm -q zabbix-web-pgsql
    check "zabbix-apache-conf is installed" \
        run_in rpm -q zabbix-apache-conf
    check "zabbix-sql-scripts is installed" \
        run_in rpm -q zabbix-sql-scripts
    check "php-pgsql is installed" \
        run_in rpm -q php-pgsql
    check "php-bcmath is installed" \
        run_in rpm -q php-bcmath
    check "php-ldap is installed" \
        run_in rpm -q php-ldap
    check "fping is installed" \
        run_in rpm -q fping
    check "glibc-langpack-en is installed" \
        run_in rpm -q glibc-langpack-en
    check "httpd is installed" \
        run_in rpm -q httpd
    check "full libcurl is installed (not minimal)" \
        run_in rpm -q libcurl
    check "libcurl-minimal is NOT installed" \
        '! run_in rpm -q libcurl-minimal'

    echo ""
    echo "--- Zabbix Version ---"
    check "zabbix-server is version 7.0.x" \
        'run_in rpm -q zabbix-server-pgsql | grep -q "^zabbix-server-pgsql-7\.0\."'

    echo ""
    echo "--- Configuration Files ---"
    check "zabbix_server.conf exists" \
        run_in test -f /etc/zabbix/zabbix_server.conf
    check "zabbix.conf.php exists" \
        run_in test -f /etc/zabbix/web/zabbix.conf.php
    check "zabbix.repo exists" \
        run_in test -f /etc/yum.repos.d/zabbix.repo
    check "zabbix apache config exists" \
        run_in test -f /etc/httpd/conf.d/zabbix.conf

    echo ""
    echo "--- Zabbix Server Config ---"
    check "DBHost is set to local socket (empty)" \
        'run_in grep -q "^DBHost=$" /etc/zabbix/zabbix_server.conf'
    check "DBName is set to zabbix" \
        'run_in grep -q "^DBName=zabbix$" /etc/zabbix/zabbix_server.conf'
    check "DBUser is set to zabbix" \
        'run_in grep -q "^DBUser=zabbix$" /etc/zabbix/zabbix_server.conf'
    check "Timeout is set to 3" \
        'run_in grep -q "^Timeout=3$" /etc/zabbix/zabbix_server.conf'

    echo ""
    echo "--- Zabbix Web Config ---"
    check "DB type is POSTGRESQL" \
        "run_in grep -q \"'POSTGRESQL'\" /etc/zabbix/web/zabbix.conf.php"
    check "DB name is zabbix" \
        "run_in grep -q \"'zabbix'\" /etc/zabbix/web/zabbix.conf.php"

    echo ""
    echo "--- Apache Config ---"
    check "Zabbix served at / (not /zabbix)" \
        'run_in grep -q "Alias / /usr/share/zabbix/" /etc/httpd/conf.d/zabbix.conf'
    check "welcome.conf is removed" \
        '! run_in test -f /etc/httpd/conf.d/welcome.conf'

    echo ""
    echo "--- Init Scripts ---"
    check "zabbix-pg-prep.sh exists" \
        run_in test -f /usr/local/bin/zabbix-pg-prep.sh
    check "zabbix-pg-prep.sh is executable" \
        run_in test -x /usr/local/bin/zabbix-pg-prep.sh
    check "zabbix-db-setup.sh exists" \
        run_in test -f /usr/local/bin/zabbix-db-setup.sh
    check "zabbix-db-setup.sh is executable" \
        run_in test -x /usr/local/bin/zabbix-db-setup.sh

    echo ""
    echo "--- Systemd Units ---"
    check "zabbix-pg-prep.service exists" \
        run_in test -f /etc/systemd/system/zabbix-pg-prep.service
    check "zabbix-db-setup.service exists" \
        run_in test -f /etc/systemd/system/zabbix-db-setup.service
    check "postgresql.service is enabled" \
        'run_in systemctl is-enabled postgresql.service'
    check "zabbix-server.service is enabled" \
        'run_in systemctl is-enabled zabbix-server.service'
    check "zabbix-pg-prep.service is enabled" \
        'run_in systemctl is-enabled zabbix-pg-prep.service'
    check "zabbix-db-setup.service is enabled" \
        'run_in systemctl is-enabled zabbix-db-setup.service'

    echo ""
    echo "--- Systemd Unit Ordering ---"
    check "pg-prep runs before postgresql" \
        'run_in grep -q "Before=postgresql.service" /etc/systemd/system/zabbix-pg-prep.service'
    check "db-setup runs after postgresql" \
        'run_in grep -q "After=postgresql.service" /etc/systemd/system/zabbix-db-setup.service'
    check "db-setup runs before zabbix-server" \
        'run_in grep -q "Before=zabbix-server.service" /etc/systemd/system/zabbix-db-setup.service'

    echo ""
    echo "--- SQL Schema ---"
    check "Zabbix SQL schema archive exists" \
        run_in test -f /usr/share/zabbix-sql-scripts/postgresql/server.sql.gz

    echo ""
    echo "--- Zabbix Web Files ---"
    check "Zabbix web root exists" \
        run_in test -d /usr/share/zabbix
    check "Zabbix index.php exists" \
        run_in test -f /usr/share/zabbix/index.php

    echo ""
    echo "--- Entrypoint ---"
    check "Entrypoint is /sbin/init" \
        '$RUNTIME inspect --format="{{json .Config.Entrypoint}}" "$IMAGE" | grep -q "/sbin/init"'
}

# =============================================================================
# RUNTIME TESTS - start container with systemd, verify services come up
# =============================================================================
run_runtime_tests() {
    echo ""
    echo "=== Runtime Tests ==="

    local CONTAINER_NAME="zabbix-test-$$"

    echo ""
    echo "--- Starting container with systemd ---"

    # Start the container with systemd (privileged required for systemd in GHA)
    $RUNTIME run -d \
        --name "$CONTAINER_NAME" \
        --privileged \
        --tmpfs /run \
        --tmpfs /tmp \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        "$IMAGE"

    # Cleanup on exit
    trap "$RUNTIME rm -f $CONTAINER_NAME >/dev/null 2>&1 || true" EXIT

    # Wait for systemd to initialize (up to 30s)
    echo "  Waiting for systemd to boot..."
    local ready=false
    for i in $(seq 1 30); do
        if $RUNTIME exec "$CONTAINER_NAME" systemctl is-system-running --wait 2>/dev/null | grep -qE "running|degraded"; then
            ready=true
            break
        fi
        sleep 1
    done

    if ! $ready; then
        echo "  WARNING: systemd did not reach running state within 30s, continuing with tests..."
    fi

    # Give services a moment to fully start (PostgreSQL init + Zabbix schema import)
    echo "  Waiting for database initialization (up to 120s)..."
    local db_ready=false
    for i in $(seq 1 120); do
        if $RUNTIME exec "$CONTAINER_NAME" su - postgres -c "psql -d zabbix -c 'SELECT 1'" >/dev/null 2>&1; then
            db_ready=true
            break
        fi
        sleep 1
    done

    if ! $db_ready; then
        echo "  WARNING: Database did not come up within 120s"
        echo "  --- Debug: systemctl status ---"
        $RUNTIME exec "$CONTAINER_NAME" systemctl status --no-pager 2>&1 || true
        echo "  --- Debug: journal ---"
        $RUNTIME exec "$CONTAINER_NAME" journalctl --no-pager -n 50 2>&1 || true
    fi

    # Helper for runtime checks
    rexec() {
        $RUNTIME exec "$CONTAINER_NAME" "$@"
    }

    echo ""
    echo "--- PostgreSQL ---"
    check "PostgreSQL data directory initialized" \
        rexec test -f /var/lib/pgsql/data/PG_VERSION
    check "PostgreSQL is running" \
        'rexec pg_isready 2>&1 | grep -q "accepting connections"'
    check "zabbix database exists" \
        'rexec su - postgres -c "psql -lqt" | grep -q zabbix'
    check "zabbix user exists" \
        'rexec su - postgres -c "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='"'"'zabbix'"'"'\"" | grep -q 1'

    echo ""
    echo "--- Zabbix Schema ---"
    # Wait a bit more for schema import if needed
    local schema_ready=false
    for i in $(seq 1 60); do
        if rexec su - postgres -c "psql -d zabbix -tc \"SELECT count(*) FROM information_schema.tables WHERE table_schema='public'\"" 2>/dev/null | tr -d ' ' | grep -qv '^0$'; then
            schema_ready=true
            break
        fi
        sleep 2
    done

    check "Zabbix schema imported (tables exist)" \
        '$schema_ready'
    check "Zabbix hosts table exists" \
        'rexec su - postgres -c "psql -d zabbix -tc \"SELECT 1 FROM information_schema.tables WHERE table_name='"'"'hosts'"'"'\"" | grep -q 1'
    check "Zabbix users table exists" \
        'rexec su - postgres -c "psql -d zabbix -tc \"SELECT 1 FROM information_schema.tables WHERE table_name='"'"'users'"'"'\"" | grep -q 1'
    check "Default Admin user exists" \
        'rexec su - postgres -c "psql -d zabbix -tc \"SELECT 1 FROM users WHERE username='"'"'Admin'"'"'\"" | grep -q 1'

    echo ""
    echo "--- Zabbix Server ---"
    # Wait for zabbix_server process to start (up to 30s after schema)
    local zbx_ready=false
    for i in $(seq 1 30); do
        if rexec pgrep -x zabbix_server >/dev/null 2>&1; then
            zbx_ready=true
            break
        fi
        sleep 1
    done

    check "zabbix-server process is running" \
        rexec pgrep -x zabbix_server
    check "zabbix-server.service is active" \
        'rexec systemctl is-active zabbix-server.service'

    echo ""
    echo "--- Apache / Zabbix Web ---"
    check "httpd process is running" \
        rexec pgrep -x httpd
    check "httpd.service is active" \
        'rexec systemctl is-active httpd.service'

    # Wait for httpd to serve pages (up to 15s)
    local web_ready=false
    for i in $(seq 1 15); do
        if rexec curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:80/ 2>/dev/null | grep -qE "200|302"; then
            web_ready=true
            break
        fi
        sleep 1
    done

    check "Zabbix web UI responds (HTTP 200 or 302)" \
        '$web_ready'
    check "Zabbix login page contains expected content" \
        'rexec curl -sL http://127.0.0.1:80/ | grep -qi zabbix'

    echo ""
    echo "--- Zabbix Server Port ---"
    check "Zabbix server listening on port 10051" \
        'rexec ss -tlnp | grep -q 10051'

    # Cleanup
    $RUNTIME rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    trap - EXIT
}

# =============================================================================
# Main
# =============================================================================
echo "============================================"
echo "Zabbix Container Image Tests"
echo "Image: $IMAGE"
echo "Mode:  $MODE"
echo "============================================"

if [[ "$MODE" == "static" || "$MODE" == "all" ]]; then
    run_static_tests
fi

if [[ "$MODE" == "runtime" || "$MODE" == "all" ]]; then
    run_runtime_tests
fi

echo ""
echo "============================================"
echo "Results: $PASS passed, $FAIL failed"
echo "============================================"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
