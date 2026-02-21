# Zabbix 7.0 on UBI 10

All-in-one Zabbix container running on Red Hat Universal Base Image 10 with systemd managing PostgreSQL, Zabbix Server, Apache, and PHP-FPM.

## What's Inside

- **Zabbix Server 7.0** (from official Zabbix RPM repo)
- **PostgreSQL 16** (from RHEL AppStream)
- **Apache httpd + PHP 8.3** (from base image)
- **systemd** as init (manages all services)

## Base Image

Built on [`quay.io/crunchtools/ubi10-httpd-php`](https://quay.io/repository/crunchtools/ubi10-httpd-php), which provides systemd, httpd, PHP 8.3, and cronie.

## Build

```bash
podman build -t localhost/zabbix:7.0 -f Containerfile .
```

## Run

```bash
podman run -d \
    --name zabbix \
    --systemd=always \
    -p 127.0.0.1:8080:8080 \
    -p 127.0.0.1:10051:10051 \
    -v /path/to/postgres-data:/var/lib/pgsql/data:Z \
    --tmpfs /etc --tmpfs /var/log --tmpfs /var/tmp \
    localhost/zabbix:7.0
```

On first run, the container will:
1. Initialize PostgreSQL if the data directory is empty
2. Create the `zabbix` database and user
3. Import the Zabbix schema

If you're migrating from Alpine-based Zabbix containers, the init scripts automatically fix UID ownership (Alpine uses UID 70, RHEL uses UID 26).

## Configuration

Before building, update these values in the Containerfile:

- **Database password**: Replace `changeme` in both `zabbix_server.conf` and `zabbix.conf.php`
- **Server name**: Replace `zabbix.example.com` in `zabbix.conf.php`

## Key Details

- **`libcurl` instead of `libcurl-minimal`**: UBI 10 ships `libcurl-minimal`, which lacks features needed by Zabbix's JavaScript HttpRequest engine. Without the full `libcurl`, Script items that make HTTPS calls (like the CloudFlare monitoring template) silently fail with timeouts.
- **`glibc-langpack-en`**: Required if your PostgreSQL data was initialized with `en_US.utf8` locale (common with Alpine-based containers).
- **`fping` from EPEL**: A hard dependency of `zabbix-server-pgsql` not available in UBI or RHEL repos.

## Blog Post

For the full story behind this container, see: [Building a Real Monitoring Stack: From 3 Alpine Containers to One UBI 10 Image with Zabbix](https://crunchtools.com/zabbix-monitoring-stack-alpine-to-ubi10/)

## License

MIT
