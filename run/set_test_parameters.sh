#!/usr/bin/env bash
#
# set_test_parameters.sh [pg_versions...]
#
# Apply the fixed "testing" GUCs we benchmark against (via ALTER SYSTEM) and
# restart the cluster, for each given version (default: PG18, the version the
# io_* knobs need; pass versions to widen). This is the companion to
# reset_all_parameters.sh - set with this, undo with that.
#
# The parameters set:
#   shared_buffers                   = 4GB    (restart)
#   work_mem                         = 64MB
#   effective_cache_size             = 12GB
#   effective_io_concurrency         = 64
#   max_parallel_workers_per_gather  = 4
#   io_combine_limit                 = 1MB    (PG18+; needs io_max_combine_limit)
#   io_max_combine_limit             = 1MB    (PG18+, restart)
#
# GUCs a version does not have (the io_* ones before PG18) are skipped with a
# note. A restart is always done, since shared_buffers and io_max_combine_limit
# require it.
#
# Run as root (ALTER SYSTEM + pg_ctlcluster need root):
#   sudo bash set_test_parameters.sh            # PG18
#   sudo bash set_test_parameters.sh 16 18      # PG16 and PG18
#
# Undo (back to PostgreSQL defaults):
#   EXTRA_PARAMS="effective_io_concurrency io_combine_limit io_max_combine_limit" \
#       sudo bash reset_all_parameters.sh [versions...]
#
set -uo pipefail

# GUCs to apply, in order (io_max_combine_limit before io_combine_limit). All
# values are single-quoted in the ALTER SYSTEM; PostgreSQL accepts quoted ints.
PAIRS=(
    "shared_buffers=4GB"
    "work_mem=64MB"
    "effective_cache_size=12GB"
    "effective_io_concurrency=64"
    "max_parallel_workers_per_gather=4"
    "io_max_combine_limit=1MB"
    "io_combine_limit=1MB"
)

VERS="${*:-18}"

TOTAL_MB=$(free -m | awk '/Mem:/{print $2}')
size_mb(){ local s="${1^^}"; case "$s" in *GB) echo $(( ${s%GB} * 1024 ));; *MB) echo $(( ${s%MB} ));; *) echo 0;; esac; }
pgq(){ sudo -u postgres psql -p "$1" -d postgres -tAc "$2" 2>/dev/null; }

# Guard: shared_buffers is the only knob here that actually allocates memory.
sb_mb=$(size_mb "$(printf '%s\n' "${PAIRS[@]}" | sed -n 's/^shared_buffers=//p')")
if [ "$sb_mb" -gt "$(( TOTAL_MB - 2048 ))" ]; then
    echo "!! shared_buffers needs > $(( TOTAL_MB - 2048 ))MB free on a ${TOTAL_MB}MB box; aborting" >&2
    exit 1
fi

for ver in $VERS; do
    read -r port < <(pg_lsclusters -h | awk -v v="$ver" '$1==v && $2=="main"{print $3}')
    if [ -z "${port:-}" ]; then
        echo "!! no PostgreSQL $ver 'main' cluster, skipping" >&2
        continue
    fi
    echo "==> PG$ver (port $port): applying testing parameters"

    for pair in "${PAIRS[@]}"; do
        name="${pair%%=*}"; value="${pair#*=}"
        # Skip GUCs this version does not have (SHOW errors -> empty).
        if [ -z "$(pgq "$port" "SHOW $name;")" ]; then
            echo "   -- $name not on PG$ver, skipping"
            continue
        fi
        pgq "$port" "ALTER SYSTEM SET $name = '$value';" >/dev/null
    done

    if pg_ctlcluster "$ver" main restart 2>/dev/null || pg_ctlcluster "$ver" main start 2>/dev/null; then
        for pair in "${PAIRS[@]}"; do
            name="${pair%%=*}"
            now=$(pgq "$port" "SHOW $name;")
            [ -n "$now" ] && echo "   PG$ver now: $name=$now"
        done
    else
        echo "!! PG$ver failed to (re)start after applying parameters" >&2
    fi
done

echo
echo "reset with: EXTRA_PARAMS=\"effective_io_concurrency io_combine_limit io_max_combine_limit\" sudo bash reset_all_parameters.sh $VERS"
