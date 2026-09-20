#!/usr/bin/env bash
#
# test_io_combine_limit.sh   (COLD-cache sweep, PostgreSQL 18+)
#
# COLD-cache benchmark swept across the PostgreSQL I/O combine limit, with the
# four knobs the other sweeps established pinned so the combine limit is the only
# thing that moves:
#   shared_buffers                   = 4GB    (fixed)
#   effective_cache_size             = 12GB   (fixed)
#   work_mem                         = 64MB   (fixed)
#   max_parallel_workers_per_gather  = 4      (fixed)
# io_combine_limit is how many adjacent blocks a scan may coalesce into one larger
# read; on PG18 it is capped by io_max_combine_limit, so BOTH are set to each
# swept value (otherwise io_combine_limit would be clamped back to the cap and the
# sweep would not move). Bigger reads matter only off disk, hence a COLD sweep
# (`make cold`: OS cache dropped and cluster restarted before every query).
#
# io_max_combine_limit is POSTMASTER context (needs a restart, not a reload), and
# the cold runner restarts before every query anyway, so each value takes effect.
#
# REQUIRES PG18+ (io_combine_limit is PG17+, io_max_combine_limit is PG18+); older
# versions lack these GUCs and are skipped. PGVERS defaults to 18 for that reason.
#
# The four fixed GUCs are applied once and the cluster restarted; then, for each
# value, io_max_combine_limit + io_combine_limit are set and the cluster restarted,
# and the cold runner runs on each database, writing THAT value's
# query_cold_<db>.csv to its own log directory. All GUCs are reset to their
# defaults on exit (the two io GUCs are passed to the reset via EXTRA_PARAMS).
#
# The VALUES and fixed values are configured HERE; databases, versions, DIR, RUNS
# come from the environment, set by `make test-io-combine-limit`.
#
# NOTE: cold runs are SLOW (restart + cache drop per query per run); scope DIR
# and keep RUNS small.
#
# Run as root:
#   sudo bash test_io_combine_limit.sh
#   sudo DRYRUN=1 bash test_io_combine_limit.sh          # print the plan, change nothing
#
set -uo pipefail

# ---- I/O combine limit sizes to sweep (128kB is the PG18 default) --------------
SIZES=(128kB 256kB 1MB)

# ---- fixed GUCs held constant across the whole sweep --------------------------
SHARED_BUFFERS="${SHARED_BUFFERS:-4GB}"
EFFECTIVE_CACHE_SIZE="${EFFECTIVE_CACHE_SIZE:-12GB}"
WORK_MEM="${WORK_MEM:-64MB}"
MAX_PARALLEL_WORKERS_PER_GATHER="${MAX_PARALLEL_WORKERS_PER_GATHER:-4}"

# The GUCs this script sweeps - named here so the reset trap (and per-value
# recovery) can clear them too. io_max_combine_limit must lead io_combine_limit.
SWEPT_GUCS="io_max_combine_limit io_combine_limit"

# ---- run configuration (from the Makefile) ------------------------------------
DBS="${DBS:-tpch tpch_idx}"
PGVERS="${PGVERS:-18}"
DIR="${DIR:-queries/tpch/tpch-queries}"
RUNS="${RUNS:-1}"
STATEMENT_TIMEOUT="${STATEMENT_TIMEOUT:-900}"
LOGS_ROOT="${LOGS_ROOT:-${LOGS_DIR:-logs}/io_combine_limit}"
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
# four - used to recover after a bad per-value restart without un-pinning them.
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

echo "io_combine_limit COLD sweep: sizes='${SIZES[*]}'  DBS='$DBS'  PGVERS='$PGVERS'  DIR='$DIR'"
echo "  fixed: shared_buffers=$SHARED_BUFFERS  effective_cache_size=$EFFECTIVE_CACHE_SIZE  work_mem=$WORK_MEM  max_parallel_workers_per_gather=$MAX_PARALLEL_WORKERS_PER_GATHER"
echo "  logs -> $LOGS_ROOT/iocl_<size>/$([ "$DRYRUN" = 1 ] && echo '   [DRY RUN]')"

for ver in $PGVERS; do
    port="$(port_of "$ver")"
    [ -n "$port" ] || { echo "!! no PG$ver cluster, skipping"; continue; }
    # Skip versions without the GUC (io_combine_limit is PG17+, io_max is PG18+).
    if [ -z "$(pgq "$port" "SHOW io_max_combine_limit;")" ]; then
        echo "== PG$ver: no io_max_combine_limit (needs PG18+), skipping"
        continue
    fi
    echo "===== PG$ver  (shared_buffers=$SHARED_BUFFERS, effective_cache_size=$EFFECTIVE_CACHE_SIZE, work_mem=$WORK_MEM, max_parallel_workers_per_gather=$MAX_PARALLEL_WORKERS_PER_GATHER) ====="

    if [ "$DRYRUN" = 1 ]; then
        for size in "${SIZES[@]}"; do
            for db in $DBS; do
                if [ "$(pgq "$port" "SELECT 1 FROM pg_database WHERE datname='$db';")" = "1" ]; then
                    echo "  ++ WOULD set io_max_combine_limit=io_combine_limit=$size, COLD-run $db -> $LOGS_ROOT/iocl_${size}"
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

    for size in "${SIZES[@]}"; do
        echo "----- PG$ver  io_combine_limit=$size (COLD) -----"
        logdir="$LOGS_ROOT/iocl_${size}"

        # io_max_combine_limit is POSTMASTER context, so a RESTART (not reload) is
        # required for the pair to take effect; the cold runner restarts anyway.
        pgq "$port" "ALTER SYSTEM SET io_max_combine_limit = '$size';" >/dev/null
        pgq "$port" "ALTER SYSTEM SET io_combine_limit = '$size';" >/dev/null
        if ! pg_ctlcluster "$ver" main restart 2>/dev/null; then
            echo "  !! PG$ver failed to restart for io_combine_limit=$size; recovering and skipping"
            recover_swept "$ver"
            continue
        fi
        echo "  applied: io_max_combine_limit=$(pgq "$port" "SHOW io_max_combine_limit;") io_combine_limit=$(pgq "$port" "SHOW io_combine_limit;")"
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
