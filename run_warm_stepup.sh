#!/usr/bin/env bash
#
# run_warm_stepup.sh
#
# Warm-data benchmark with a per-query cold start. Every query in DIR is run
# REPEATS times, in a single RANDOM order across the whole set (generated and
# SAVED up front). For each entry the loop is:
#
#   1. drop the OS page cache + restart the cluster   (a clean, cold start)
#   2. WARMUP unmeasured runs                          (warm this query's data)
#   3. step-up measured batches: N = BATCH_SIZES        (N copies of the query in
#      (default 1 2 4 8 16)                              one psql process, warm)
#
# So each query is measured WARM (steps 2-3), but from an identical cold starting
# point (step 1), with no cache carried over from whatever ran before it. The
# random order is over all REPEATS x queries, so run-order effects wash out.
#
# The measurement itself is query_runner (via `make run`): step 3 is its
# BATCH_SIZES step-up mode, step 2 is its WARMUP. This script owns the ORDER and
# the per-query restart + cache drop; query_runner owns the timing/energy/CSVs.
# It does NOT set the tuning GUCs - run set_test_parameters.sh first and
# reset_all_parameters.sh after.
#
# EACH RUN IS ISOLATED. A unique RUNID (UTC timestamp + random, overridable) names
# a per-run folder $LOGS_ROOT/<RUNID>/ that holds this run's order
# (run_order_<RUNID>.txt), result CSVs (query_timing_<db>.csv, ...), console.log
# and summary.txt - so a new run never overwrites an earlier one's order or logs.
# summary.txt (also echoed) records the TOTAL RUNTIME of the run.
#
# Config (all overridable from the environment; the Makefile's warm-stepup sets
# them): DIR REPEATS WARMUP BATCH_SIZES RUNS DB_NAME PGVER LOGS_ROOT RUNID
# STATEMENT_TIMEOUT ORDER_FILE DRYRUN.
#
# Run as root (drop_caches, pg_ctlcluster and the RAPL runner all need root):
#   sudo bash run_warm_stepup.sh
#   sudo DRYRUN=1 bash run_warm_stepup.sh      # generate+save the order, run nothing
#   sudo ORDER_FILE=logs/warm_stepup/<RUNID>/run_order_<RUNID>.txt bash run_warm_stepup.sh  # replay
#
set -uo pipefail

DIR="${DIR:-queries/tpch/tpch-queries}"
REPEATS="${REPEATS:-3}"               # X: times each query is run
WARMUP="${WARMUP:-2}"                 # unmeasured warm-up runs per entry
BATCH_SIZES="${BATCH_SIZES:-1 2 4 8 16}"  # step-up batch sizes (N copies)
RUNS="${RUNS:-1}"                     # measured batches per size
DB_NAME="${DB_NAME:-tpch}"            # single database (set tpch_idx for the indexed run)
PGVER="${PGVER:-18}"
LOGS_ROOT="${LOGS_ROOT:-logs/warm_stepup}"
STATEMENT_TIMEOUT="${STATEMENT_TIMEOUT:-900}"
ORDER_FILE="${ORDER_FILE:-}"          # replay this saved order if it exists
DRYRUN="${DRYRUN:-0}"

# A unique id per run so each run's order + result CSVs land in their OWN folder
# ($LOGS_ROOT/<RUNID>/) and never overwrite a previous run's. Auto-generated
# (UTC timestamp + random) unless the caller sets RUNID.
_rand=$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'); [ -n "$_rand" ] || _rand=$$
RUNID="${RUNID:-$(date -u +%Y%m%dT%H%M%SZ)-$_rand}"

HERE="$(cd "$(dirname "$0")" && pwd)"
port_of(){ pg_lsclusters -h | awk -v v="$1" '$1==v && $2=="main"{print $3}'; }
PORT="$(port_of "$PGVER")"
[ -n "$PORT" ] || { echo "!! no PG$PGVER 'main' cluster; aborting" >&2; exit 1; }

# Dropping caches and restarting need root; skip the check for a dry run.
if [ "$DRYRUN" != 1 ] && [ "$(id -u)" != 0 ]; then
    echo "!! must run as root (drop_caches + pg_ctlcluster); use sudo" >&2
    exit 1
fi

# Everything for THIS run lives under its own RUNID folder, so a later run never
# overwrites it. The order file carries the RUNID in its name too.
RUN_DIR="$LOGS_ROOT/$RUNID"
mkdir -p "$RUN_DIR"
saved_order="$RUN_DIR/run_order_$RUNID.txt"

# --- 1. Build (or replay) and SAVE the random run order ------------------------
if [ -n "$ORDER_FILE" ] && [ -f "$ORDER_FILE" ]; then
    echo "==> replaying saved order: $ORDER_FILE"
    mapfile -t ORDER < <(grep -vE '^\s*(#|$)' "$ORDER_FILE")
    src_note="# replayed from $ORDER_FILE"
else
    mapfile -t QUERIES < <(find "$DIR" -type f -name '*.sql' | sort)
    [ "${#QUERIES[@]}" -gt 0 ] || { echo "!! no .sql files under $DIR; aborting" >&2; exit 1; }
    # REPEATS copies of the query list, shuffled into one random order.
    mapfile -t ORDER < <(for ((r = 0; r < REPEATS; r++)); do printf '%s\n' "${QUERIES[@]}"; done | shuf)
    src_note="# generated fresh: $((${#QUERIES[@]})) queries x $REPEATS repeats"
fi
total="${#ORDER[@]}"
# Save the order actually used (generated OR replayed), tagged with the RUNID.
{
    echo "# warm step-up run order"
    echo "# run_id=$RUNID"
    echo "# generated $(date -u +%Y-%m-%dT%H:%M:%SZ)  DIR=$DIR  REPEATS=$REPEATS  total=$total"
    echo "$src_note"
    printf '%s\n' "${ORDER[@]}"
} > "$saved_order"
echo "==> run_id=$RUNID  order ($total entries) -> $saved_order"

echo "warm step-up: PG$PGVER  DB=$DB_NAME  DIR=$DIR  BATCH_SIZES='$BATCH_SIZES'  WARMUP=$WARMUP  RUNS=$RUNS"
echo "  logs -> $RUN_DIR/  ($total entries)$([ "$DRYRUN" = 1 ] && echo '   [DRY RUN]')"

if [ "$DRYRUN" = 1 ]; then
    echo "  first entries:"
    printf '    %s\n' "${ORDER[@]:0:10}"
    [ "$total" -gt 10 ] && echo "    ... ($((total - 10)) more)"
    echo "  [DRY RUN] order saved; nothing restarted or run."
    exit 0
fi

# --- The per-entry loop --------------------------------------------------------
console="$RUN_DIR/console.log"
: > "$console"
run_started=$(date +%s)
start_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ok=0; fail=0
for i in "${!ORDER[@]}"; do
    qfile="${ORDER[$i]}"
    n=$((i + 1))
    echo "[$n/$total] $qfile"

    # 1. clean cold start: drop OS page cache + restart the cluster.
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || echo "  WARN: could not drop caches"
    if ! pg_ctlcluster "$PGVER" main restart >/dev/null 2>&1; then
        echo "  !! restart failed; skipping this entry"; fail=$((fail + 1)); continue
    fi
    # wait until the server accepts connections again
    ready=0
    for _ in $(seq 1 30); do
        [ "$(sudo -u postgres psql -p "$PORT" -d "$DB_NAME" -tAc 'SELECT 1;' 2>/dev/null)" = "1" ] && { ready=1; break; }
        sleep 1
    done
    [ "$ready" = 1 ] || { echo "  !! $DB_NAME not ready after restart; skipping"; fail=$((fail + 1)); continue; }

    # Snapshot relation sizes once (first entry); skip it on the rest.
    skip_catalog=1; [ "$n" = 1 ] && skip_catalog=""

    # 2 (WARMUP) + 3 (BATCH_SIZES step-up) are query_runner's job, on this ONE file.
    if make -C "$HERE" run PGVER="$PGVER" DB_NAME="$DB_NAME" DIR="$qfile" \
         WARMUP="$WARMUP" BATCH_SIZES="$BATCH_SIZES" RUNS="$RUNS" WORKERS="" \
         STATEMENT_TIMEOUT="$STATEMENT_TIMEOUT" SKIP_CATALOG="$skip_catalog" \
         LOGS_DIR="$RUN_DIR" >> "$console" 2>&1; then
        echo "  ok"; ok=$((ok + 1))
    else
        echo "  FAILED (see $console)"; fail=$((fail + 1))
    fi
done

run_ended=$(date +%s)
dur=$((run_ended - run_started))
fmt=$(printf '%02d:%02d:%02d' $((dur / 3600)) $(((dur % 3600) / 60)) $((dur % 60)))
avg="n/a"; [ "$total" -gt 0 ] && avg="$((dur / total))s"

# Total runtime + tallies at the end of the run's logs (summary.txt) and stdout.
{
    echo "run_id:        $RUNID"
    echo "db:            $DB_NAME   pg:            $PGVER"
    echo "started_utc:   $start_iso"
    echo "finished_utc:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "entries:       $total   ok: $ok   failed: $fail"
    echo "total_runtime: $fmt  ($dur seconds)   avg_per_entry: $avg"
} | tee "$RUN_DIR/summary.txt"

echo
echo "warm step-up done: $ok ok, $fail failed of $total entries in $fmt"
echo "  results dir: $RUN_DIR/  (query_timing_${DB_NAME}.csv, ..., summary.txt)"
echo "  order: $saved_order   console: $console"
