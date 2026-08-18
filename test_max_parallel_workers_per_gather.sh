#!/usr/bin/env bash
#
# test_max_parallel_workers_per_gather.sh
#
# Warm-cache benchmark swept across PostgreSQL max_parallel_workers_per_gather
# values, with the other memory knobs pinned so parallelism is the only thing
# that moves:
#   shared_buffers          = 4GB    (fixed)
#   effective_cache_size    = 12GB   (fixed)
#   work_mem                = 64MB   (fixed)
# The three fixed GUCs are applied once per version (ALTER SYSTEM) and the
# cluster is restarted once (shared_buffers needs a restart). Then, for each
# max_parallel_workers_per_gather value, it is set (ALTER SYSTEM) and the config
# reloaded - no restart, so shared_buffers stays warm - and the normal warm-cache
# runner (`make run`) runs on each database, writing THAT value's results to its
# own log directory. All four GUCs are reset to their defaults when the script
# exits, however it exits (see the trap / reset_all_parameters.sh).
#
# NOTE: max_parallel_workers_per_gather is capped by the cluster's
# max_parallel_workers / max_worker_processes (both default 8), so values above
# that are silently clamped by PostgreSQL - the sweep values here (2/4/6) are
# under the default cap.
#
# The VALUES and the three fixed values are configured HERE (overridable from the
# environment). Everything else - which databases, which versions, DIR,
# RUNS/WARMUP/BATCHNUM, ... - comes from the environment, set by
# `make test-max-parallel-workers`.
#
# Run as root (ALTER SYSTEM, pg_ctlcluster and the RAPL runner all need root):
#   sudo bash test_max_parallel_workers_per_gather.sh
#   sudo DRYRUN=1 bash test_max_parallel_workers_per_gather.sh   # print the plan, change nothing
#
set -uo pipefail

# ---- max_parallel_workers_per_gather values to sweep (2 is the PG default) -----
SIZES=(2 4 6)

# ---- fixed GUCs held constant across the whole sweep --------------------------
SHARED_BUFFERS="${SHARED_BUFFERS:-4GB}"
EFFECTIVE_CACHE_SIZE="${EFFECTIVE_CACHE_SIZE:-12GB}"
WORK_MEM="${WORK_MEM:-64MB}"

# ---- run configuration (from the Makefile) ------------------------------------
DBS="${DBS:-tpch tpch_idx}"
PGVERS="${PGVERS:-14 16 18}"
DIR="${DIR:-queries/tpch}"
RUNS="${RUNS:-1}"
WARMUP="${WARMUP:-2}"
BATCHNUM="${BATCHNUM:-1}"
STATEMENT_TIMEOUT="${STATEMENT_TIMEOUT:-900}"
LOGS_ROOT="${LOGS_ROOT:-logs/max_parallel_workers}"
DRYRUN="${DRYRUN:-0}"

HERE="$(cd "$(dirname "$0")" && pwd)"
TOTAL_MB=$(free -m | awk '/Mem:/{print $2}')
# shared_buffers is fixed and it is the only knob here that actually allocates
# memory. Leave headroom so the server can still start; bail out if this box
# can't seat the fixed shared_buffers, since we can't shrink it without changing
# the test.
MAX_SB_MB=$(( TOTAL_MB - 2048 ))

port_of(){ pg_lsclusters -h | awk -v v="$1" '$1==v && $2=="main"{print $3}'; }
pgq(){ sudo -u postgres psql -p "$1" -d postgres -tAc "$2" 2>/dev/null; }
size_mb(){ local s="${1^^}"; case "$s" in *GB) echo $(( ${s%GB} * 1024 ));; *MB) echo $(( ${s%MB} ));; *) echo 0;; esac; }

# Whatever happens, put all four GUCs back to their defaults on every version we
# touched (delegates to the standalone reset script).
cleanup(){ [ "$DRYRUN" = 1 ] && return; echo; echo "==> resetting all tuned parameters to default"; bash "$HERE/reset_all_parameters.sh" $PGVERS; }
trap cleanup EXIT INT TERM

if [ "$(size_mb "$SHARED_BUFFERS")" -gt "$MAX_SB_MB" ]; then
    echo "!! fixed shared_buffers=$SHARED_BUFFERS needs > ${MAX_SB_MB}MB free on a ${TOTAL_MB}MB box; aborting" >&2
    exit 1
fi

echo "max_parallel_workers_per_gather sweep: values='${SIZES[*]}'  DBS='$DBS'  PGVERS='$PGVERS'  DIR='$DIR'"
echo "  fixed: shared_buffers=$SHARED_BUFFERS  effective_cache_size=$EFFECTIVE_CACHE_SIZE  work_mem=$WORK_MEM"
echo "  logs -> $LOGS_ROOT/mpw_<n>/$([ "$DRYRUN" = 1 ] && echo '   [DRY RUN]')"

for ver in $PGVERS; do
    port="$(port_of "$ver")"
    [ -n "$port" ] || { echo "!! no PG$ver cluster, skipping"; continue; }
    echo "===== PG$ver  (shared_buffers=$SHARED_BUFFERS, effective_cache_size=$EFFECTIVE_CACHE_SIZE, work_mem=$WORK_MEM) ====="

    if [ "$DRYRUN" = 1 ]; then
        for n in "${SIZES[@]}"; do
            for db in $DBS; do
                if [ "$(pgq "$port" "SELECT 1 FROM pg_database WHERE datname='$db';")" = "1" ]; then
                    echo "  ++ WOULD set max_parallel_workers_per_gather=$n, warm-run $db -> $LOGS_ROOT/mpw_${n}"
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
    if ! pg_ctlcluster "$ver" main restart 2>/dev/null; then
        echo "  !! PG$ver failed to restart with the fixed parameters; resetting and skipping"
        bash "$HERE/reset_all_parameters.sh" "$ver"
        continue
    fi
    echo "  applied: shared_buffers=$(pgq "$port" "SHOW shared_buffers;") effective_cache_size=$(pgq "$port" "SHOW effective_cache_size;") work_mem=$(pgq "$port" "SHOW work_mem;")"

    for n in "${SIZES[@]}"; do
        echo "----- PG$ver  max_parallel_workers_per_gather=$n -----"
        logdir="$LOGS_ROOT/mpw_${n}"

        # max_parallel_workers_per_gather is reloadable, so a SIGHUP is enough -
        # no restart, keeping shared_buffers warm across the sweep.
        pgq "$port" "ALTER SYSTEM SET max_parallel_workers_per_gather = $n;" >/dev/null
        if ! pg_ctlcluster "$ver" main reload 2>/dev/null; then
            echo "  !! PG$ver failed to reload for max_parallel_workers_per_gather=$n; skipping"
            continue
        fi
        echo "  applied: max_parallel_workers_per_gather=$(pgq "$port" "SHOW max_parallel_workers_per_gather;")"
        mkdir -p "$logdir"

        for db in $DBS; do
            if [ "$(pgq "$port" "SELECT 1 FROM pg_database WHERE datname='$db';")" != "1" ]; then
                echo "  -- $db not on PG$ver, skipping"
                continue
            fi
            echo "  -> warm run: PG$ver $db"
            # WORKERS is forced empty so the runner does NOT add a per-session
            # max_parallel_workers_per_gather override - the swept server value
            # (set above) is what we want to measure.
            if make -C "$HERE" run PGVER="$ver" DB_NAME="$db" DIR="$DIR" \
                 RUNS="$RUNS" WARMUP="$WARMUP" BATCHNUM="$BATCHNUM" WORKERS="" \
                 STATEMENT_TIMEOUT="$STATEMENT_TIMEOUT" LOGS_DIR="$logdir" \
                 > "$logdir/run_pg${ver}_${db}.log" 2>&1; then
                echo "     ok  (CSVs + console log in $logdir)"
            else
                echo "     FAILED (see $logdir/run_pg${ver}_${db}.log)"
            fi
        done
    done
done
# cleanup() runs here on EXIT and resets all four parameters to their defaults.
