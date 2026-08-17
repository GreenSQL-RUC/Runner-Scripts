#!/usr/bin/env bash
#
# reset_all_parameters.sh [pg_versions...]
#
# Reset the GUCs that the tuning sweeps override back to their PostgreSQL
# defaults and restart the cluster, for each given version (default: every
# installed 'main' cluster). It strips the ALTER SYSTEM overrides straight out
# of postgresql.auto.conf, so it works even when the server is DOWN because a
# too-large setting (e.g. shared_buffers) stopped it from starting - which is
# exactly when you need it.
#
# The parameters reset (all set by test_shared_buffer.sh / test_work_mem.sh):
#   shared_buffers  work_mem  effective_cache_size  max_parallel_workers_per_gather
#
# Use if test_shared_buffer.sh or test_work_mem.sh was interrupted / crashed and
# left non-default settings. Run as root:
#   sudo bash reset_all_parameters.sh          # all installed versions
#   sudo bash reset_all_parameters.sh 18       # just PG18
#
set -uo pipefail

# The GUCs to strip from postgresql.auto.conf.
PARAMS=(shared_buffers work_mem effective_cache_size max_parallel_workers_per_gather)

VERS="${*:-$(pg_lsclusters -h | awk '$2 == "main" { print $1 }')}"

for ver in $VERS; do
    # pg_lsclusters -h columns: Ver Cluster Port Status Owner Data-dir Log-file
    read -r port datadir < <(pg_lsclusters -h | awk -v v="$ver" '$1==v && $2=="main"{print $3, $6}')
    if [ -z "${datadir:-}" ]; then
        echo "!! no PostgreSQL $ver 'main' cluster, skipping" >&2
        continue
    fi
    auto="$datadir/postgresql.auto.conf"
    echo "==> PG$ver: removing overrides (${PARAMS[*]}) + restarting"
    if [ -f "$auto" ]; then
        for p in "${PARAMS[@]}"; do
            sed -i "/^${p}[[:space:]]*=/d" "$auto"
        done
    fi
    if pg_ctlcluster "$ver" main restart 2>/dev/null || pg_ctlcluster "$ver" main start 2>/dev/null; then
        for p in "${PARAMS[@]}"; do
            now=$(sudo -u postgres psql -p "$port" -d postgres -tAc "SHOW $p;" 2>/dev/null)
            echo "   PG$ver now: $p=${now:-?}"
        done
    else
        echo "!! PG$ver failed to (re)start after reset" >&2
    fi
done
