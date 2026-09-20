#!/usr/bin/env bash
#
# test_io_method.sh   (COLD-cache sweep, PostgreSQL 18+)
#
# COLD-cache benchmark swept across the PostgreSQL 18 I/O method (how the new
# asynchronous I/O subsystem issues reads), with the four knobs the other sweeps
# established pinned so the I/O method is the only thing that moves:
#   shared_buffers                   = 4GB    (fixed)
#   effective_cache_size             = 12GB   (fixed)
#   work_mem                         = 64MB   (fixed)
#   max_parallel_workers_per_gather  = 4      (fixed)
# The swept configurations are:
#   worker with io_workers = 1, 3, 6   (io_method=worker, N background io workers)
#   io_uring                           (io_method=io_uring; needs a liburing build)
#   sync                               (io_method=sync; the old synchronous path)
# The method only matters when reads hit disk, hence a COLD sweep (`make cold`:
# OS cache dropped and cluster restarted before every query).
#
# io_method is POSTMASTER context (needs a restart, not a reload); io_workers is
# reloadable but only used by io_method=worker. The cold runner restarts before
# every query anyway, so each configuration takes effect. If a version's build
# lacks io_uring, that configuration's restart fails and it is recovered+skipped.
#
# REQUIRES PG18+ (io_method / io_workers are new in PG18); older versions are
# skipped. PGVERS defaults to 18 for that reason.
#
# All GUCs are reset to their defaults on exit (io_method + io_workers via
# EXTRA_PARAMS). Configurations are configured HERE; databases, versions, DIR,
# RUNS come from the environment, set by `make test-io-method`.
#
# NOTE: cold runs are SLOW (restart + cache drop per query per run); scope DIR
# and keep RUNS small.
#
# Run as root:
#   sudo bash test_io_method.sh
#   sudo DRYRUN=1 bash test_io_method.sh                 # print the plan, change nothing
#
set -uo pipefail

# ---- I/O method configurations to sweep. "worker:N" = io_method=worker with N
#      io_workers; a bare name = io_method=<name>. (worker/3 is the PG18 default) -
CONFIGS=(worker:1 worker:3 worker:6 io_uring sync)

# ---- fixed GUCs held constant across the whole sweep --------------------------
SHARED_BUFFERS="${SHARED_BUFFERS:-4GB}"
EFFECTIVE_CACHE_SIZE="${EFFECTIVE_CACHE_SIZE:-12GB}"
WORK_MEM="${WORK_MEM:-64MB}"
MAX_PARALLEL_WORKERS_PER_GATHER="${MAX_PARALLEL_WORKERS_PER_GATHER:-4}"

# The GUCs this script sweeps - named here so the reset trap (and per-value
# recovery) can clear them too.
SWEPT_GUCS="io_method io_workers"

# ---- run configuration (from the Makefile) ------------------------------------
DBS="${DBS:-tpch tpch_idx}"
PGVERS="${PGVERS:-18}"
DIR="${DIR:-queries/tpch/tpch-queries}"
RUNS="${RUNS:-1}"
STATEMENT_TIMEOUT="${STATEMENT_TIMEOUT:-900}"
LOGS_ROOT="${LOGS_ROOT:-${LOGS_DIR:-logs}/io_method}"
DRYRUN="${DRYRUN:-0}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"          # repo root (this script lives in test/)
TOTAL_MB=$(free -m | awk '/Mem:/{print $2}')
MAX_SB_MB=$(( TOTAL_MB - 2048 ))

port_of(){ pg_lsclusters -h | awk -v v="$1" '$1==v && $2=="main"{print $3}'; }
datadir_of(){ pg_lsclusters -h | awk -v v="$1" '$1==v && $2=="main"{print $6}'; }
pgq(){ sudo -u postgres psql -p "$1" -d postgres -tAc "$2" 2>/dev/null; }
size_mb(){ local s="${1^^}"; case "$s" in *GB) echo $(( ${s%GB} * 1024 ));; *MB) echo $(( ${s%MB} ));; *) echo 0;; esac; }

# Strip the swept GUCs from a version's auto.conf and restart, KEEPING the fixed
# four - used to recover after a bad per-config restart (e.g. io_uring on a build
# without liburing) without un-pinning them.
recover_swept(){
    local v="$1" auto; auto="$(datadir_of "$v")/postgresql.auto.conf"
    [ -f "$auto" ] && for g in $SWEPT_GUCS; do sed -i "/^${g}[[:space:]]*=/d" "$auto"; done
    pg_ctlcluster "$v" main restart 2>/dev/null || pg_ctlcluster "$v" main start 2>/dev/null
}

# Whatever happens, put the four fixed GUCs AND the swept ones back to their
# defaults on every version we touched (delegates to the standalone reset script).
cleanup(){ [ "$DRYRUN" = 1 ] && return; echo; echo "==> resetting all tuned parameters to default"; EXTRA_PARAMS="$SWEPT_GUCS" bash "$ROOT/run/reset_all_parameters.sh" $PGVERS; }
trap cleanup EXIT INT TERM

if [ "$(size_mb "$SHARED_BUFFERS")" -gt "$MAX_SB_MB" ]; then
    echo "!! fixed shared_buffers=$SHARED_BUFFERS needs > ${MAX_SB_MB}MB free on a ${TOTAL_MB}MB box; aborting" >&2
    exit 1
fi

echo "io_method COLD sweep: configs='${CONFIGS[*]}'  DBS='$DBS'  PGVERS='$PGVERS'  DIR='$DIR'"
echo "  fixed: shared_buffers=$SHARED_BUFFERS  effective_cache_size=$EFFECTIVE_CACHE_SIZE  work_mem=$WORK_MEM  max_parallel_workers_per_gather=$MAX_PARALLEL_WORKERS_PER_GATHER"
echo "  logs -> $LOGS_ROOT/iom_<config>/$([ "$DRYRUN" = 1 ] && echo '   [DRY RUN]')"

for ver in $PGVERS; do
    port="$(port_of "$ver")"
    [ -n "$port" ] || { echo "!! no PG$ver cluster, skipping"; continue; }
    # Skip versions without the GUC (io_method / io_workers are new in PG18).
    if [ -z "$(pgq "$port" "SHOW io_method;")" ]; then
        echo "== PG$ver: no io_method (needs PG18+), skipping"
        continue
    fi
    echo "===== PG$ver  (shared_buffers=$SHARED_BUFFERS, effective_cache_size=$EFFECTIVE_CACHE_SIZE, work_mem=$WORK_MEM, max_parallel_workers_per_gather=$MAX_PARALLEL_WORKERS_PER_GATHER) ====="

    if [ "$DRYRUN" = 1 ]; then
        for spec in "${CONFIGS[@]}"; do
            for db in $DBS; do
                if [ "$(pgq "$port" "SELECT 1 FROM pg_database WHERE datname='$db';")" = "1" ]; then
                    echo "  ++ WOULD set io_method(${spec}), COLD-run $db -> $LOGS_ROOT/iom_${spec/:/_io}"
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
        EXTRA_PARAMS="$SWEPT_GUCS" bash "$ROOT/run/reset_all_parameters.sh" "$ver"
        continue
    fi
    echo "  applied: shared_buffers=$(pgq "$port" "SHOW shared_buffers;") effective_cache_size=$(pgq "$port" "SHOW effective_cache_size;") work_mem=$(pgq "$port" "SHOW work_mem;") max_parallel_workers_per_gather=$(pgq "$port" "SHOW max_parallel_workers_per_gather;")"

    for spec in "${CONFIGS[@]}"; do
        method="${spec%%:*}"
        if [[ "$spec" == *:* ]]; then workers="${spec#*:}"; else workers=""; fi
        label="${spec/:/_io}"
        echo "----- PG$ver  io_method=$method${workers:+ io_workers=$workers} (COLD) -----"
        logdir="$LOGS_ROOT/iom_${label}"

        # io_method is POSTMASTER context, so a RESTART (not reload) is required;
        # the cold runner restarts before each query anyway. io_workers is only
        # meaningful for io_method=worker, so it is set only then.
        pgq "$port" "ALTER SYSTEM SET io_method = '$method';" >/dev/null
        [ -n "$workers" ] && pgq "$port" "ALTER SYSTEM SET io_workers = $workers;" >/dev/null
        if ! pg_ctlcluster "$ver" main restart 2>/dev/null; then
            echo "  !! PG$ver failed to restart for io_method=$method (build may lack it); recovering and skipping"
            recover_swept "$ver"
            continue
        fi
        echo "  applied: io_method=$(pgq "$port" "SHOW io_method;") io_workers=$(pgq "$port" "SHOW io_workers;")"
        mkdir -p "$logdir"

        for db in $DBS; do
            if [ "$(pgq "$port" "SELECT 1 FROM pg_database WHERE datname='$db';")" != "1" ]; then
                echo "  -- $db not on PG$ver, skipping"
                continue
            fi
            echo "  -> COLD run: PG$ver $db"
            # WORKERS forced empty so the cold runner does NOT add a per-session
            # max_parallel_workers_per_gather override - the fixed server value applies.
            if make -C "$ROOT" cold PGVER="$ver" DB_NAME="$db" DIR="$DIR" \
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
# cleanup() runs here on EXIT and resets every parameter to its default.
