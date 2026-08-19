#!/usr/bin/env bash
#
# test_effective_io_concurrency.sh   (COLD-cache sweep)
#
# COLD-cache benchmark swept across PostgreSQL effective_io_concurrency values,
# with the four knobs the other sweeps established pinned so I/O concurrency is
# the only thing that moves:
#   shared_buffers                   = 4GB    (fixed)
#   effective_cache_size             = 12GB   (fixed)
#   work_mem                         = 64MB   (fixed)
#   max_parallel_workers_per_gather  = 4      (fixed)
# effective_io_concurrency sets how many concurrent I/O requests a scan may issue
# (prefetch depth), so it only shows up when reads actually hit disk - hence this
# is a COLD sweep (`make cold`: the OS page cache is dropped and the cluster
# restarted before every query, so nothing is served from RAM).
#
# The four fixed GUCs are applied once per version (ALTER SYSTEM) and the cluster
# restarted once. Then, for each value, effective_io_concurrency is set (ALTER
# SYSTEM) and the config reloaded, and the cold runner runs on each database,
# writing THAT value's query_cold_<db>.csv to its own log directory. All five
# GUCs are reset to their defaults when the script exits (effective_io_concurrency
# is passed to the reset via EXTRA_PARAMS).
#
# The VALUES and the four fixed values are configured HERE (overridable from the
# environment). Everything else - databases, versions, DIR, RUNS - comes from the
# environment, set by `make test-effective-io-concurrency`.
#
# NOTE: cold runs are SLOW (restart + cache drop per query per run); scope DIR
# and keep RUNS small.
#
# Run as root (ALTER SYSTEM, pg_ctlcluster, cache-drop and the RAPL runner need root):
#   sudo bash test_effective_io_concurrency.sh
#   sudo DRYRUN=1 bash test_effective_io_concurrency.sh   # print the plan, change nothing
#
set -uo pipefail

# ---- effective_io_concurrency values to sweep (1 is the PG default) -----------
SIZES=(0 16 64 256)

# ---- fixed GUCs held constant across the whole sweep --------------------------
SHARED_BUFFERS="${SHARED_BUFFERS:-4GB}"
EFFECTIVE_CACHE_SIZE="${EFFECTIVE_CACHE_SIZE:-12GB}"
WORK_MEM="${WORK_MEM:-64MB}"
MAX_PARALLEL_WORKERS_PER_GATHER="${MAX_PARALLEL_WORKERS_PER_GATHER:-4}"

# The GUC this script sweeps - named here so the reset trap can clear it too.
SWEPT_GUC="effective_io_concurrency"

# ---- run configuration (from the Makefile) ------------------------------------
DBS="${DBS:-tpch tpch_idx}"
PGVERS="${PGVERS:-14 16 18}"
DIR="${DIR:-queries/tpch}"
RUNS="${RUNS:-1}"
STATEMENT_TIMEOUT="${STATEMENT_TIMEOUT:-900}"
LOGS_ROOT="${LOGS_ROOT:-logs/effective_io_concurrency}"
DRYRUN="${DRYRUN:-0}"

HERE="$(cd "$(dirname "$0")" && pwd)"
TOTAL_MB=$(free -m | awk '/Mem:/{print $2}')
MAX_SB_MB=$(( TOTAL_MB - 2048 ))

port_of(){ pg_lsclusters -h | awk -v v="$1" '$1==v && $2=="main"{print $3}'; }
pgq(){ sudo -u postgres psql -p "$1" -d postgres -tAc "$2" 2>/dev/null; }
size_mb(){ local s="${1^^}"; case "$s" in *GB) echo $(( ${s%GB} * 1024 ));; *MB) echo $(( ${s%MB} ));; *) echo 0;; esac; }

# Whatever happens, put the four fixed GUCs AND the swept one back to their
# defaults on every version we touched (delegates to the standalone reset script).
cleanup(){ [ "$DRYRUN" = 1 ] && return; echo; echo "==> resetting all tuned parameters to default"; EXTRA_PARAMS="$SWEPT_GUC" bash "$HERE/reset_all_parameters.sh" $PGVERS; }
trap cleanup EXIT INT TERM

if [ "$(size_mb "$SHARED_BUFFERS")" -gt "$MAX_SB_MB" ]; then
    echo "!! fixed shared_buffers=$SHARED_BUFFERS needs > ${MAX_SB_MB}MB free on a ${TOTAL_MB}MB box; aborting" >&2
    exit 1
fi

echo "effective_io_concurrency COLD sweep: values='${SIZES[*]}'  DBS='$DBS'  PGVERS='$PGVERS'  DIR='$DIR'"
echo "  fixed: shared_buffers=$SHARED_BUFFERS  effective_cache_size=$EFFECTIVE_CACHE_SIZE  work_mem=$WORK_MEM  max_parallel_workers_per_gather=$MAX_PARALLEL_WORKERS_PER_GATHER"
echo "  logs -> $LOGS_ROOT/eic_<n>/$([ "$DRYRUN" = 1 ] && echo '   [DRY RUN]')"

for ver in $PGVERS; do
    port="$(port_of "$ver")"
    [ -n "$port" ] || { echo "!! no PG$ver cluster, skipping"; continue; }
    echo "===== PG$ver  (shared_buffers=$SHARED_BUFFERS, effective_cache_size=$EFFECTIVE_CACHE_SIZE, work_mem=$WORK_MEM, max_parallel_workers_per_gather=$MAX_PARALLEL_WORKERS_PER_GATHER) ====="

    if [ "$DRYRUN" = 1 ]; then
        for n in "${SIZES[@]}"; do
            for db in $DBS; do
                if [ "$(pgq "$port" "SELECT 1 FROM pg_database WHERE datname='$db';")" = "1" ]; then
                    echo "  ++ WOULD set effective_io_concurrency=$n, COLD-run $db -> $LOGS_ROOT/eic_${n}"
                else
                    echo "  -- $db not on PG$ver, would skip"
                fi
            done
        done
        continue
    fi

    # Fixed GUCs: set once, restart once (shared_buffers needs a restart).
    pgq "$port" "ALTER SYSTEM SET shared_buffers = '$SHARED_BUFFERS';" >/dev/null
    pgq "$port" "ALTER SYSTEM SET effective_cache_size = '$EFFECTIVE_CACHE_SIZE';" >/dev/null
    pgq "$port" "ALTER SYSTEM SET work_mem = '$WORK_MEM';" >/dev/null
    pgq "$port" "ALTER SYSTEM SET max_parallel_workers_per_gather = $MAX_PARALLEL_WORKERS_PER_GATHER;" >/dev/null
    if ! pg_ctlcluster "$ver" main restart 2>/dev/null; then
        echo "  !! PG$ver failed to restart with the fixed parameters; resetting and skipping"
        EXTRA_PARAMS="$SWEPT_GUC" bash "$HERE/reset_all_parameters.sh" "$ver"
        continue
    fi
    echo "  applied: shared_buffers=$(pgq "$port" "SHOW shared_buffers;") effective_cache_size=$(pgq "$port" "SHOW effective_cache_size;") work_mem=$(pgq "$port" "SHOW work_mem;") max_parallel_workers_per_gather=$(pgq "$port" "SHOW max_parallel_workers_per_gather;")"

    for n in "${SIZES[@]}"; do
        echo "----- PG$ver  effective_io_concurrency=$n (COLD) -----"
        logdir="$LOGS_ROOT/eic_${n}"

        # effective_io_concurrency is reloadable; the cold runner restarts the
        # cluster before each query anyway, so the value stays in effect.
        pgq "$port" "ALTER SYSTEM SET effective_io_concurrency = $n;" >/dev/null
        if ! pg_ctlcluster "$ver" main reload 2>/dev/null; then
            echo "  !! PG$ver failed to reload for effective_io_concurrency=$n; skipping"
            continue
        fi
        echo "  applied: effective_io_concurrency=$(pgq "$port" "SHOW effective_io_concurrency;")"
        mkdir -p "$logdir"

        for db in $DBS; do
            if [ "$(pgq "$port" "SELECT 1 FROM pg_database WHERE datname='$db';")" != "1" ]; then
                echo "  -- $db not on PG$ver, skipping"
                continue
            fi
            echo "  -> COLD run: PG$ver $db"
            # WORKERS forced empty so the cold runner does NOT add a per-session
            # max_parallel_workers_per_gather override - the fixed server value applies.
            if make -C "$HERE" cold PGVER="$ver" DB_NAME="$db" DIR="$DIR" \
                 RUNS="$RUNS" WORKERS="" STATEMENT_TIMEOUT="$STATEMENT_TIMEOUT" \
                 LOGS_DIR="$logdir" \
                 > "$logdir/cold_pg${ver}_${db}.log" 2>&1; then
                echo "     ok  (query_cold_<db>.csv + console log in $logdir)"
            else
                echo "     FAILED (see $logdir/cold_pg${ver}_${db}.log)"
            fi
        done
    done
done
# cleanup() runs here on EXIT and resets all five parameters to their defaults.
