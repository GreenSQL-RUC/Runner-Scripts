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
#   shared_buffers                   = 4GB    (restart; SHARED_BUFFERS overrides)
#   work_mem                         = 64MB
#   effective_cache_size             = 12GB   (EFFECTIVE_CACHE_SIZE overrides)
#   effective_io_concurrency         = 64
#   max_parallel_workers_per_gather  = 4      (MAX_PARALLEL_WORKERS_PER_GATHER overrides)
#   max_parallel_workers             = PostgreSQL's default 8 (MAX_PARALLEL_WORKERS overrides;
#   max_worker_processes             = default 8   with it set, MAX_PARALLEL_WORKERS + 8, restart)
#   min_parallel_table_scan_size     = PostgreSQL's default 8MB (MIN_PARALLEL_TABLE_SCAN_SIZE overrides)
#   min_parallel_index_scan_size     = PostgreSQL's default 512kB (MIN_PARALLEL_INDEX_SCAN_SIZE overrides)
#   io_combine_limit                 = 1MB    (PG18+; needs io_max_combine_limit)
#   io_max_combine_limit             = 1MB    (PG18+, restart)
#
# GUCs a version does not have (the io_* ones before PG18) are skipped with a
# note. A restart is always done, since shared_buffers and io_max_combine_limit
# require it.
#
# SHARED_BUFFERS / EFFECTIVE_CACHE_SIZE (e.g. 16GB, 512MB) size those two for a
# machine with more or less memory than the 16 GB laptops; unset = the values
# above. A CloudLab node from cloudlab/profile.py exports them in login shells.
#
# Parallel query: how many workers a query gets is the SMALLEST of
#   - max_parallel_workers_per_gather (here 4);
#   - the planner's size rule: a scan gets 1 worker once its table reaches
#     min_parallel_table_scan_size (8MB), or its index min_parallel_index_scan_size
#     (512kB) for a parallel index scan, and one more each time it triples. On
#     stackoverflow_1gb that is 4 for posthistory (493 MB) and posts (246 MB),
#     3 for comments, 2 for users/votes/badges, and 4 for posthistory_pkey
#     (18 MB) - so per-gather above 4 changes nothing there unless the two
#     thresholds are lowered too (checked on PG18: 8 per gather with 1MB / 64kB
#     gives posthistory 6 workers, by seq scan and by index-only scan alike);
#   - what is free in the pool, max_parallel_workers (8) inside
#     max_worker_processes (8), shared by every query running at that moment.
#     A warm step-up batch runs its N copies one after another in one psql
#     session, so a single query at a time: the pool only binds if per-gather
#     goes above 8. MAX_PARALLEL_WORKERS raises it (and max_worker_processes to
#     it + 8, room for the other background workers).
# Unset, MAX_PARALLEL_WORKERS and the two MIN_PARALLEL_* are RESET to the
# defaults, so a run without them is always at 8 / 8MB / 512kB whatever an
# earlier run set. workers_launched in query_samples_<db>.csv shows what each copy got.
#
# Run as root (ALTER SYSTEM + pg_ctlcluster need root):
#   sudo bash set_test_parameters.sh            # PG18
#   sudo bash set_test_parameters.sh 16 18      # PG16 and PG18
#   sudo SHARED_BUFFERS=16GB EFFECTIVE_CACHE_SIZE=48GB bash set_test_parameters.sh 16
#
# Undo (back to PostgreSQL defaults):
#   EXTRA_PARAMS="effective_io_concurrency io_combine_limit io_max_combine_limit" \
#       sudo bash reset_all_parameters.sh [versions...]
#
set -uo pipefail

# GUCs to apply, in order (io_max_combine_limit before io_combine_limit). All
# values are single-quoted in the ALTER SYSTEM; PostgreSQL accepts quoted ints.
SHARED_BUFFERS="${SHARED_BUFFERS:-4GB}"
EFFECTIVE_CACHE_SIZE="${EFFECTIVE_CACHE_SIZE:-12GB}"
MPWG="${MAX_PARALLEL_WORKERS_PER_GATHER:-4}"
MPW="${MAX_PARALLEL_WORKERS:-}"
MPTSS="${MIN_PARALLEL_TABLE_SCAN_SIZE:-}"
MPISS="${MIN_PARALLEL_INDEX_SCAN_SIZE:-}"
for v in "$SHARED_BUFFERS" "$EFFECTIVE_CACHE_SIZE"; do
    [[ "$v" =~ ^[0-9]+(MB|GB)$ ]] || { echo "!! sizes must look like 512MB or 4GB, got '$v'; aborting" >&2; exit 1; }
done
[[ "$MPWG" =~ ^[0-9]+$ ]] || { echo "!! MAX_PARALLEL_WORKERS_PER_GATHER must be a whole number, got '$MPWG'; aborting" >&2; exit 1; }
[[ -z "$MPW" || "$MPW" =~ ^[0-9]+$ ]] || { echo "!! MAX_PARALLEL_WORKERS must be a whole number, got '$MPW'; aborting" >&2; exit 1; }
for v in "$MPTSS" "$MPISS"; do
    [[ -z "$v" || "$v" =~ ^[0-9]+(kB|MB|GB)?$ ]] || { echo "!! MIN_PARALLEL_*_SCAN_SIZE must look like 0, 64kB or 1MB, got '$v'; aborting" >&2; exit 1; }
done
[ "$MPWG" -le "${MPW:-8}" ] \
    || echo "   note: max_parallel_workers_per_gather=$MPWG is above the pool of ${MPW:-8} (MAX_PARALLEL_WORKERS), so PostgreSQL caps it" >&2
# DEFAULT = ALTER SYSTEM RESET (back to PostgreSQL's default).
PAIRS=(
    "shared_buffers=$SHARED_BUFFERS"
    "work_mem=64MB"
    "effective_cache_size=$EFFECTIVE_CACHE_SIZE"
    "effective_io_concurrency=64"
    "max_worker_processes=$([ -n "$MPW" ] && echo $((MPW + 8)) || echo DEFAULT)"
    "max_parallel_workers=${MPW:-DEFAULT}"
    "max_parallel_workers_per_gather=$MPWG"
    "min_parallel_table_scan_size=${MPTSS:-DEFAULT}"
    "min_parallel_index_scan_size=${MPISS:-DEFAULT}"
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
        if [ "$value" = DEFAULT ]; then
            pgq "$port" "ALTER SYSTEM RESET $name;" >/dev/null
        else
            pgq "$port" "ALTER SYSTEM SET $name = '$value';" >/dev/null
        fi
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
