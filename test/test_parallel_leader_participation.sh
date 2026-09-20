#!/usr/bin/env bash
#
# test_parallel_leader_participation.sh
#
# Warm-cache benchmark run with parallel_leader_participation ON vs OFF, with the
# four knobs the other sweeps established pinned so leader participation is the
# only thing that moves:
#   shared_buffers                   = 4GB    (fixed)
#   effective_cache_size             = 12GB   (fixed)
#   work_mem                         = 64MB   (fixed)
#   max_parallel_workers_per_gather  = 4      (fixed)
# parallel_leader_participation decides whether the leader process also executes
# a parallel plan's subplan (on) or only gathers the workers' output (off), so
# this contrasts the two with a fixed 4-worker cap.
#
# The four fixed GUCs are applied once per version (ALTER SYSTEM) and the cluster
# is restarted once (shared_buffers needs a restart). Then, for on and off,
# parallel_leader_participation is set (ALTER SYSTEM) and the config reloaded - no
# restart, so shared_buffers stays warm - and the normal warm-cache runner
# (`make run`) runs on each database, writing THAT setting's results to its own
# log directory. All five GUCs are reset to their defaults when the script exits,
# however it exits (parallel_leader_participation is passed to the reset via
# EXTRA_PARAMS).
#
# The VALUES and the four fixed values are configured HERE (overridable from the
# environment). Everything else - which databases, which versions, DIR,
# RUNS/WARMUP/BATCH_SIZES, ... - comes from the environment, set by
# `make test-parallel-leader-participation`.
#
# Run as root (ALTER SYSTEM, pg_ctlcluster and the RAPL runner all need root):
#   sudo bash test_parallel_leader_participation.sh
#   sudo DRYRUN=1 bash test_parallel_leader_participation.sh   # print the plan, change nothing
#
set -uo pipefail

# ---- parallel_leader_participation settings to sweep (on is the PG default) ----
SIZES=(on off)

# ---- fixed GUCs held constant across the whole sweep --------------------------
SHARED_BUFFERS="${SHARED_BUFFERS:-4GB}"
EFFECTIVE_CACHE_SIZE="${EFFECTIVE_CACHE_SIZE:-12GB}"
WORK_MEM="${WORK_MEM:-64MB}"
MAX_PARALLEL_WORKERS_PER_GATHER="${MAX_PARALLEL_WORKERS_PER_GATHER:-4}"

# The GUC this script sweeps - named here so the reset trap can clear it too.
SWEPT_GUC="parallel_leader_participation"

# ---- run configuration (from the Makefile) ------------------------------------
DBS="${DBS:-tpch tpch_idx}"
PGVERS="${PGVERS:-15 16 17 18}"
DIR="${DIR:-queries/tpch/tpch-queries}"
RUNS="${RUNS:-1}"
WARMUP="${WARMUP:-2}"
BATCH_SIZES="${BATCH_SIZES:-1 16}"
STATEMENT_TIMEOUT="${STATEMENT_TIMEOUT:-900}"
LOGS_ROOT="${LOGS_ROOT:-${LOGS_DIR:-logs}/parallel_leader_participation}"
DRYRUN="${DRYRUN:-0}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"          # repo root (this script lives in test/)
TOTAL_MB=$(free -m | awk '/Mem:/{print $2}')
# shared_buffers is fixed and it is the only knob here that actually allocates
# memory. Leave headroom so the server can still start; bail out if this box
# can't seat the fixed shared_buffers, since we can't shrink it without changing
# the test.
MAX_SB_MB=$(( TOTAL_MB - 2048 ))

port_of(){ pg_lsclusters -h | awk -v v="$1" '$1==v && $2=="main"{print $3}'; }
pgq(){ sudo -u postgres psql -p "$1" -d postgres -tAc "$2" 2>/dev/null; }
size_mb(){ local s="${1^^}"; case "$s" in *GB) echo $(( ${s%GB} * 1024 ));; *MB) echo $(( ${s%MB} ));; *) echo 0;; esac; }

# Whatever happens, put the four fixed GUCs AND the swept one back to their
# defaults on every version we touched (delegates to the standalone reset script).
cleanup(){ [ "$DRYRUN" = 1 ] && return; echo; echo "==> resetting all tuned parameters to default"; EXTRA_PARAMS="$SWEPT_GUC" bash "$ROOT/run/reset_all_parameters.sh" $PGVERS; }
trap cleanup EXIT INT TERM

if [ "$(size_mb "$SHARED_BUFFERS")" -gt "$MAX_SB_MB" ]; then
    echo "!! fixed shared_buffers=$SHARED_BUFFERS needs > ${MAX_SB_MB}MB free on a ${TOTAL_MB}MB box; aborting" >&2
    exit 1
fi

echo "parallel_leader_participation sweep: values='${SIZES[*]}'  DBS='$DBS'  PGVERS='$PGVERS'  DIR='$DIR'"
echo "  fixed: shared_buffers=$SHARED_BUFFERS  effective_cache_size=$EFFECTIVE_CACHE_SIZE  work_mem=$WORK_MEM  max_parallel_workers_per_gather=$MAX_PARALLEL_WORKERS_PER_GATHER"
echo "  logs -> $LOGS_ROOT/plp_<on|off>/$([ "$DRYRUN" = 1 ] && echo '   [DRY RUN]')"

for ver in $PGVERS; do
    port="$(port_of "$ver")"
    [ -n "$port" ] || { echo "!! no PG$ver cluster, skipping"; continue; }
    echo "===== PG$ver  (shared_buffers=$SHARED_BUFFERS, effective_cache_size=$EFFECTIVE_CACHE_SIZE, work_mem=$WORK_MEM, max_parallel_workers_per_gather=$MAX_PARALLEL_WORKERS_PER_GATHER) ====="

    if [ "$DRYRUN" = 1 ]; then
        for v in "${SIZES[@]}"; do
            for db in $DBS; do
                if [ "$(pgq "$port" "SELECT 1 FROM pg_database WHERE datname='$db';")" = "1" ]; then
                    echo "  ++ WOULD set parallel_leader_participation=$v, warm-run $db -> $LOGS_ROOT/plp_${v}"
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
        EXTRA_PARAMS="$SWEPT_GUC" bash "$ROOT/run/reset_all_parameters.sh" "$ver"
        continue
    fi
    echo "  applied: shared_buffers=$(pgq "$port" "SHOW shared_buffers;") effective_cache_size=$(pgq "$port" "SHOW effective_cache_size;") work_mem=$(pgq "$port" "SHOW work_mem;") max_parallel_workers_per_gather=$(pgq "$port" "SHOW max_parallel_workers_per_gather;")"

    for v in "${SIZES[@]}"; do
        echo "----- PG$ver  parallel_leader_participation=$v -----"
        logdir="$LOGS_ROOT/plp_${v}"

        # parallel_leader_participation is reloadable, so a SIGHUP is enough - no
        # restart, keeping shared_buffers warm across the sweep.
        pgq "$port" "ALTER SYSTEM SET parallel_leader_participation = $v;" >/dev/null
        if ! pg_ctlcluster "$ver" main reload 2>/dev/null; then
            echo "  !! PG$ver failed to reload for parallel_leader_participation=$v; skipping"
            continue
        fi
        echo "  applied: parallel_leader_participation=$(pgq "$port" "SHOW parallel_leader_participation;")"
        mkdir -p "$logdir"

        for db in $DBS; do
            if [ "$(pgq "$port" "SELECT 1 FROM pg_database WHERE datname='$db';")" != "1" ]; then
                echo "  -- $db not on PG$ver, skipping"
                continue
            fi
            echo "  -> warm run: PG$ver $db"
            # WORKERS is forced empty so the runner does NOT add a per-session
            # max_parallel_workers_per_gather override - the fixed server value
            # (set above) is what we want to measure against.
            if make -C "$ROOT" run PGVER="$ver" DB_NAME="$db" DIR="$DIR" \
                 RUNS="$RUNS" WARMUP="$WARMUP" BATCH_SIZES="$BATCH_SIZES" WORKERS="" \
                 STATEMENT_TIMEOUT="$STATEMENT_TIMEOUT" LOGS_DIR="$logdir" \
                 > "$logdir/run_pg${ver}_${db}.log" 2>&1; then
                echo "     ok  (CSVs + console log in $logdir)"
            else
                echo "     FAILED (see $logdir/run_pg${ver}_${db}.log)"
            fi
        done
    done
done
# cleanup() runs here on EXIT and resets all five parameters to their defaults.
