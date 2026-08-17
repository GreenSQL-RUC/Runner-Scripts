#!/usr/bin/env bash
#
# work_mem_plans.sh
#
# Like test_work_mem.sh, but instead of timing the queries it draws out their
# PLANS (via plan_builder / `make plans`) at each work_mem value, with the other
# memory/parallelism knobs pinned so work_mem is the only thing that moves:
#   shared_buffers                   = 4GB   (fixed)
#   effective_cache_size             = 12GB  (fixed)
#   max_parallel_workers_per_gather  = 4     (fixed)
# The three fixed GUCs are applied once per version (ALTER SYSTEM) and the
# cluster is restarted once (shared_buffers needs a restart). Then, for each
# work_mem value, work_mem is set (ALTER SYSTEM) and the config reloaded - no
# restart - and plan_builder saves every query's plan for each database.
#
# plan_builder runs EXPLAIN ANALYZE, so the saved plans reflect work_mem both in
# the shape the planner chose AND in execution (e.g. "Sort Method: quicksort
# Memory:" vs "external merge Disk:") - which is the point of sweeping it.
#
# OUTPUT ISOLATION: each value's plans go to their OWN root,
#   $PLANS_ROOT/wm_<size>/<db>/...      (default PLANS_ROOT=plans/work_mem)
# which is separate from the top-level plans/tpch and plans/tpch_idx, so nothing
# already in plans/ is overwritten. Both the base (tpch) and indexed (tpch_idx)
# databases are done.
#
# All four GUCs are reset to their defaults when the script exits, however it
# exits (see the trap / reset_all_parameters.sh).
#
# The work_mem SIZES and the three fixed values are configured HERE (overridable
# from the environment). Everything else - which databases, which versions, DIR -
# comes from the environment, set by `make plans-work-mem`.
#
# Run as root (ALTER SYSTEM, pg_ctlcluster and plan_builder's psql all need root):
#   sudo bash work_mem_plans.sh
#   sudo DRYRUN=1 bash work_mem_plans.sh      # print the plan, change nothing
#
set -uo pipefail

# ---- work_mem values to sweep (4MB is the PostgreSQL default) -----------------
SIZES=(4MB 16MB 32MB 64MB 128MB)

# ---- fixed GUCs held constant across the whole sweep --------------------------
SHARED_BUFFERS="${SHARED_BUFFERS:-4GB}"
EFFECTIVE_CACHE_SIZE="${EFFECTIVE_CACHE_SIZE:-12GB}"
MAX_PARALLEL_WORKERS_PER_GATHER="${MAX_PARALLEL_WORKERS_PER_GATHER:-4}"

# ---- run configuration (from the Makefile) ------------------------------------
DBS="${DBS:-tpch tpch_idx}"
PGVERS="${PGVERS:-14 16 18}"
DIR="${DIR:-queries/tpch}"
PLANS_ROOT="${PLANS_ROOT:-plans/work_mem}"
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

echo "work_mem PLAN sweep: sizes='${SIZES[*]}'  DBS='$DBS'  PGVERS='$PGVERS'  DIR='$DIR'"
echo "  fixed: shared_buffers=$SHARED_BUFFERS  effective_cache_size=$EFFECTIVE_CACHE_SIZE  max_parallel_workers_per_gather=$MAX_PARALLEL_WORKERS_PER_GATHER"
echo "  plans -> $PLANS_ROOT/wm_<size>/<db>/   (separate from existing plans/)$([ "$DRYRUN" = 1 ] && echo '   [DRY RUN]')"

for ver in $PGVERS; do
    port="$(port_of "$ver")"
    [ -n "$port" ] || { echo "!! no PG$ver cluster, skipping"; continue; }
    echo "===== PG$ver  (shared_buffers=$SHARED_BUFFERS, effective_cache_size=$EFFECTIVE_CACHE_SIZE, max_parallel_workers_per_gather=$MAX_PARALLEL_WORKERS_PER_GATHER) ====="

    if [ "$DRYRUN" = 1 ]; then
        for size in "${SIZES[@]}"; do
            for db in $DBS; do
                if [ "$(pgq "$port" "SELECT 1 FROM pg_database WHERE datname='$db';")" = "1" ]; then
                    echo "  ++ WOULD set work_mem=$size, plan $db -> $PLANS_ROOT/wm_${size}/$db"
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
    pgq "$port" "ALTER SYSTEM SET max_parallel_workers_per_gather = $MAX_PARALLEL_WORKERS_PER_GATHER;" >/dev/null
    if ! pg_ctlcluster "$ver" main restart 2>/dev/null; then
        echo "  !! PG$ver failed to restart with the fixed parameters; resetting and skipping"
        bash "$HERE/reset_all_parameters.sh" "$ver"
        continue
    fi
    echo "  applied: shared_buffers=$(pgq "$port" "SHOW shared_buffers;") effective_cache_size=$(pgq "$port" "SHOW effective_cache_size;") max_parallel_workers_per_gather=$(pgq "$port" "SHOW max_parallel_workers_per_gather;")"

    for size in "${SIZES[@]}"; do
        echo "----- PG$ver  work_mem=$size -----"
        plandir="$PLANS_ROOT/wm_${size}"

        # work_mem is reloadable, so a SIGHUP is enough - no restart needed.
        pgq "$port" "ALTER SYSTEM SET work_mem = '$size';" >/dev/null
        if ! pg_ctlcluster "$ver" main reload 2>/dev/null; then
            echo "  !! PG$ver failed to reload for work_mem=$size; skipping"
            continue
        fi
        echo "  applied: work_mem=$(pgq "$port" "SHOW work_mem;")"
        mkdir -p "$plandir"

        for db in $DBS; do
            if [ "$(pgq "$port" "SELECT 1 FROM pg_database WHERE datname='$db';")" != "1" ]; then
                echo "  -- $db not on PG$ver, skipping"
                continue
            fi
            echo "  -> plans: PG$ver $db"
            # plan_builder writes under PLANS_DIR/<DB_NAME>/, so this value's own
            # root keeps it clear of the top-level plans/. WORKERS is forced empty
            # so the plans reflect the fixed server max_parallel_workers_per_gather
            # rather than a per-session override.
            if make -C "$HERE" plans PGVER="$ver" DB_NAME="$db" DIR="$DIR" \
                 PLANS_DIR="$plandir" WORKERS="" \
                 > "$plandir/plan_pg${ver}_${db}.log" 2>&1; then
                echo "     ok  (plans + console log in $plandir)"
            else
                echo "     FAILED (see $plandir/plan_pg${ver}_${db}.log)"
            fi
        done
    done
done
# cleanup() runs here on EXIT and resets all four parameters to their defaults.
