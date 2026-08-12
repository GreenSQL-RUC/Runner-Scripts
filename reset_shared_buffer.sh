#!/usr/bin/env bash
#
# reset_shared_buffer.sh [pg_versions...]
#
# Reset shared_buffers back to the PostgreSQL default and restart the cluster,
# for each given version (default: every installed 'main' cluster). It removes
# the ALTER SYSTEM override straight out of postgresql.auto.conf, so it works
# even when the server is DOWN because a too-large shared_buffers stopped it from
# starting - which is exactly when you need it.
#
# Use if test_shared_buffer.sh was interrupted / crashed and left a non-default
# shared_buffers. Run as root:
#   sudo bash reset_shared_buffer.sh          # all installed versions
#   sudo bash reset_shared_buffer.sh 18       # just PG18
#
set -uo pipefail

VERS="${*:-$(pg_lsclusters -h | awk '$2 == "main" { print $1 }')}"

for ver in $VERS; do
    # pg_lsclusters -h columns: Ver Cluster Port Status Owner Data-dir Log-file
    read -r port datadir < <(pg_lsclusters -h | awk -v v="$ver" '$1==v && $2=="main"{print $3, $6}')
    if [ -z "${datadir:-}" ]; then
        echo "!! no PostgreSQL $ver 'main' cluster, skipping" >&2
        continue
    fi
    auto="$datadir/postgresql.auto.conf"
    echo "==> PG$ver: removing shared_buffers override + restarting"
    [ -f "$auto" ] && sed -i '/^shared_buffers/d' "$auto"
    if pg_ctlcluster "$ver" main restart 2>/dev/null || pg_ctlcluster "$ver" main start 2>/dev/null; then
        now=$(sudo -u postgres psql -p "$port" -d postgres -tAc "SHOW shared_buffers;" 2>/dev/null)
        echo "   PG$ver now: shared_buffers=${now:-?}"
    else
        echo "!! PG$ver failed to (re)start after reset" >&2
    fi
done
