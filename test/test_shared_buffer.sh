#!/usr/bin/env bash
#
# test_shared_buffer.sh
#
# Warm-cache benchmark swept across PostgreSQL shared_buffers sizes. For each size
# it sets shared_buffers (ALTER SYSTEM) and restarts the cluster, then runs the
# normal warm-cache runner (`make run`) on each database, writing THAT size's
# results to its own log directory. shared_buffers is reset to the default when
# the script exits, however it exits (see the trap).
#
# The shared_buffers SIZES are configured HERE. Everything else - which databases,
# which versions, DIR, RUNS/WARMUP/BATCH_SIZES, ... - comes from the environment,
# set by `make test-shared-buffer`.
#
# Run as root (ALTER SYSTEM, pg_ctlcluster and the RAPL runner all need root):
#   sudo bash test_shared_buffer.sh
#   sudo DRYRUN=1 bash test_shared_buffer.sh      # print the plan, change nothing
#
set -uo pipefail

# ---- shared_buffers sizes to sweep (128MB is the PostgreSQL default) ----------
SIZES=(128MB 512MB 1GB 4GB 8GB)

# ---- run configuration (from the Makefile) ------------------------------------
DBS="${DBS:-tpch tpch_idx}"
PGVERS="${PGVERS:-15 16 17 18}"
DIR="${DIR:-queries/tpch/tpch-queries}"
RUNS="${RUNS:-1}"
WARMUP="${WARMUP:-2}"
BATCH_SIZES="${BATCH_SIZES:-1 16}"
WORKERS="${WORKERS:-}"
STATEMENT_TIMEOUT="${STATEMENT_TIMEOUT:-900}"
LOGS_ROOT="${LOGS_ROOT:-${LOGS_DIR:-logs}/shared_buffers}"
DRYRUN="${DRYRUN:-0}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"          # repo root (this script lives in test/)
TOTAL_MB=$(free -m | awk '/Mem:/{print $2}')
# Leave headroom so the server can still start (shared_buffers is not the only
# memory postgres needs). Any size larger than this is skipped.
MAX_SB_MB=$(( TOTAL_MB - 2048 ))

port_of(){ pg_lsclusters -h | awk -v v="$1" '$1==v && $2=="main"{print $3}'; }
pgq(){ sudo -u postgres psql -p "$1" -d postgres -tAc "$2" 2>/dev/null; }
size_mb(){ local s="${1^^}"; case "$s" in *GB) echo $(( ${s%GB} * 1024 ));; *MB) echo $(( ${s%MB} ));; *) echo 0;; esac; }

# Whatever happens, put shared_buffers back to the default on every version we
# touched (delegates to the standalone reset script).
cleanup(){ [ "$DRYRUN" = 1 ] && return; echo; echo "==> resetting shared_buffers to default"; bash "$ROOT/run/reset_all_parameters.sh" $PGVERS; }
trap cleanup EXIT INT TERM

echo "shared_buffers sweep: sizes='${SIZES[*]}'  DBS='$DBS'  PGVERS='$PGVERS'  DIR='$DIR'"
echo "  logs -> $LOGS_ROOT/sb_<size>/   (RAM=${TOTAL_MB}MB; skipping sizes > ${MAX_SB_MB}MB)$([ "$DRYRUN" = 1 ] && echo '   [DRY RUN]')"

for ver in $PGVERS; do
    port="$(port_of "$ver")"
    [ -n "$port" ] || { echo "!! no PG$ver cluster, skipping"; continue; }
    for size in "${SIZES[@]}"; do
        if [ "$(size_mb "$size")" -gt "$MAX_SB_MB" ]; then
            echo "== PG$ver shared_buffers=$size: SKIP (needs > ${MAX_SB_MB}MB free on a ${TOTAL_MB}MB box)"
            continue
        fi
        echo "===== PG$ver  shared_buffers=$size ====="
        logdir="$LOGS_ROOT/sb_${size}"

        if [ "$DRYRUN" = 1 ]; then
            for db in $DBS; do
                if [ "$(pgq "$port" "SELECT 1 FROM pg_database WHERE datname='$db';")" = "1" ]; then
                    echo "  ++ WOULD set shared_buffers=$size, restart PG$ver, warm-run $db -> $logdir"
                else
                    echo "  -- $db not on PG$ver, would skip"
                fi
            done
            continue
        fi

        pgq "$port" "ALTER SYSTEM SET shared_buffers = '$size';" >/dev/null
        if ! pg_ctlcluster "$ver" main restart 2>/dev/null; then
            echo "  !! PG$ver failed to restart at shared_buffers=$size; resetting and skipping"
            bash "$ROOT/run/reset_all_parameters.sh" "$ver"
            continue
        fi
        echo "  applied: shared_buffers=$(pgq "$port" "SHOW shared_buffers;")"
        mkdir -p "$logdir"

        for db in $DBS; do
            if [ "$(pgq "$port" "SELECT 1 FROM pg_database WHERE datname='$db';")" != "1" ]; then
                echo "  -- $db not on PG$ver, skipping"
                continue
            fi
            echo "  -> warm run: PG$ver $db"
            if make -C "$ROOT" run PGVER="$ver" DB_NAME="$db" DIR="$DIR" \
                 RUNS="$RUNS" WARMUP="$WARMUP" BATCH_SIZES="$BATCH_SIZES" WORKERS="$WORKERS" \
                 STATEMENT_TIMEOUT="$STATEMENT_TIMEOUT" LOGS_DIR="$logdir" \
                 > "$logdir/run_pg${ver}_${db}.log" 2>&1; then
                echo "     ok  (CSVs + console log in $logdir)"
            else
                echo "     FAILED (see $logdir/run_pg${ver}_${db}.log)"
            fi
        done
    done
done
# cleanup() runs here on EXIT and resets shared_buffers to the default.
