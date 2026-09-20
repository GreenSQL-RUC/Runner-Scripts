#!/usr/bin/env bash
#
# run_warm_stepup.sh - THE warm step-up benchmark driver (`make warm-stepup`).
#
# Every query in DIR is run REPEATS times, in ONE random order over all
# REPEATS x queries (generated and SAVED up front, replayable). For each entry:
#
#   1. cold start: drop the OS page cache + restart the cluster
#   2. [thermal equalisation - OFF by default, see THERMAL_EQUALISE]
#   3. WARMUP unmeasured single-copy runs           (warm this query's data)
#   4. step-up: RUNS measured batches at each N in BATCH_SIZES (N copies of
#      the query in one psql process), warm
#
# Steps 2-4 are query_runner (bin/query_runner) on that ONE file; this script
# owns the order, the cold start, the per-entry run ids and the run folder.
# It does NOT set the tuning GUCs: `make set-parameters` first, reset after.
#
# EACH RUN IS ISOLATED under $LOGS_ROOT/<RUNID>/ (RUNID = UTC stamp + random,
# overridable): run_order_<RUNID>.txt, query_timing_<db>.csv,
# query_samples_<db>.csv, query_catalog_<db>.csv, console.log, summary.txt.
#
# THERMAL STATE (run/thermal_runner_brief.md): every batch row records the
# package temperature at start, its mean/max during the batch, CPU MHz,
# throttle counts and the idle gap before it. Two OPTIONAL protocol knobs,
# both OFF by default:
#   THERMAL_EQUALISE=1|gate|burn  equalise the die temperature before each
#                                 entry (query_runner does it; preheat_s /
#                                 cooldown_wait_s land on the entry's first row)
#   CLOCK_MAX_KHZ=2500000         with FIX_CLOCK=1, pin to this ceiling (kHz)
#                                 instead of the base frequency
#   FIX_CLOCK=1                   pin the clock (performance governor, capped) for the
#                                 whole run, restored at the end (also on Ctrl-C)
# summary.txt records the clock/RAPL power-limit state and the policy used, and
# run_order_<RUNID>.txt lists "# order: <n> <run_id> prev=<run_id>" so the
# carry-over between consecutive groups is a direct join on run_id.
#
# Config (environment; `make warm-stepup` sets them): DIR REPEATS WARMUP
# BATCH_SIZES RUNS DB_NAME PGVER LOGS_DIR (root for logs, default logs) or
# LOGS_ROOT (default $LOGS_DIR/warm_stepup) RUNID ORDER_FILE STATEMENT_TIMEOUT
# WORKERS THERMAL_EQUALISE T_LO T_HI PREHEAT_MAX_S COOLDOWN_MAX_S PREHEAT_S
# FIX_CLOCK BATCH_CAP_SLOW SLOW_COPY_SEC DRYRUN BIN.
#
#   sudo bash run/run_warm_stepup.sh
#   sudo DRYRUN=1 bash run/run_warm_stepup.sh                  # save the order only
#   sudo ORDER_FILE=logs/warm_stepup/<RUNID>/run_order_<RUNID>.txt bash run/run_warm_stepup.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"                 # repo root (this script lives in run/)
BIN="${BIN:-$ROOT/bin}"

DIR="${DIR:-queries/tpch/tpch-queries}"
REPEATS="${REPEATS:-1}"
WARMUP="${WARMUP:-2}"
BATCH_SIZES="${BATCH_SIZES:-1 16}"
RUNS="${RUNS:-1}"
DB_NAME="${DB_NAME:-tpch}"
DB_USER="${DB_USER:-postgres}"
PGVER="${PGVER:-18}"
LOGS_DIR="${LOGS_DIR:-logs}"
LOGS_ROOT="${LOGS_ROOT:-$LOGS_DIR/warm_stepup}"
STATEMENT_TIMEOUT="${STATEMENT_TIMEOUT:-900}"
WORKERS="${WORKERS:-}"
ORDER_FILE="${ORDER_FILE:-}"
DRYRUN="${DRYRUN:-0}"
THERMAL_EQUALISE="${THERMAL_EQUALISE:-0}"
FIX_CLOCK="${FIX_CLOCK:-0}"
CLOCK_MAX_KHZ="${CLOCK_MAX_KHZ:-}"
BATCH_CAP_SLOW="${BATCH_CAP_SLOW:-}"
SLOW_COPY_SEC="${SLOW_COPY_SEC:-1}"
T_LO="${T_LO:-55}"; T_HI="${T_HI:-60}"; PREHEAT_MAX_S="${PREHEAT_MAX_S:-60}"
COOLDOWN_MAX_S="${COOLDOWN_MAX_S:-120}"; PREHEAT_S="${PREHEAT_S:-30}"
[ "$DRYRUN" = "" ] && DRYRUN=0
[ "$FIX_CLOCK" = "" ] && FIX_CLOCK=0
[ "$THERMAL_EQUALISE" = "" ] && THERMAL_EQUALISE=0

_rand=$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'); [ -n "$_rand" ] || _rand=$$
RUNID="${RUNID:-$(date -u +%Y%m%dT%H%M%SZ)-$_rand}"

cd "$ROOT" || exit 1
port_of(){ pg_lsclusters -h | awk -v v="$1" '$1==v && $2=="main"{print $3}'; }
PORT="$(port_of "$PGVER")"
[ -n "$PORT" ] || { echo "!! no PG$PGVER 'main' cluster; aborting" >&2; exit 1; }
[ -x "$BIN/query_runner" ] || { echo "!! $BIN/query_runner missing - run make first" >&2; exit 1; }

if [ "$DRYRUN" != 1 ] && [ "$(id -u)" != 0 ]; then
    echo "!! must run as root (drop_caches + pg_ctlcluster + RAPL); use sudo" >&2
    exit 1
fi

RUN_DIR="$LOGS_ROOT/$RUNID"
mkdir -p "$RUN_DIR"
saved_order="$RUN_DIR/run_order_$RUNID.txt"
console="$RUN_DIR/console.log"

# --- 1. Build (or replay) the random order, assign per-entry run ids, SAVE ----
if [ -n "$ORDER_FILE" ] && [ -f "$ORDER_FILE" ]; then
    echo "==> replaying saved order: $ORDER_FILE"
    mapfile -t ORDER < <(grep -vE '^\s*(#|$)' "$ORDER_FILE")
    src_note="# replayed from $ORDER_FILE"
else
    if [ -f "$DIR" ]; then QUERIES=("$DIR")
    else mapfile -t QUERIES < <(find "$DIR" -type f -name '*.sql' | sort); fi
    [ "${#QUERIES[@]}" -gt 0 ] || { echo "!! no .sql files under $DIR; aborting" >&2; exit 1; }
    mapfile -t ORDER < <(for ((r = 0; r < REPEATS; r++)); do printf '%s\n' "${QUERIES[@]}"; done | shuf)
    src_note="# generated fresh: ${#QUERIES[@]} queries x $REPEATS repeats"
fi
total="${#ORDER[@]}"
n_queries=$(printf '%s\n' "${ORDER[@]}" | sort -u | grep -c .)

# One 16-hex run_id per entry, generated up front so the order file can state
# each group's predecessor (brief 3c) and every CSV row of the group carries it.
IDS=()
for ((i = 0; i < total; i++)); do
    IDS+=("$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n' | tr 'a-f' 'A-F')")
done

thermal_policy="$THERMAL_EQUALISE"
case "$thermal_policy" in
    1|gate|on) thermal_policy="gate T_LO=$T_LO T_HI=$T_HI PREHEAT_MAX_S=$PREHEAT_MAX_S COOLDOWN_MAX_S=$COOLDOWN_MAX_S" ;;
    burn)      thermal_policy="burn PREHEAT_S=$PREHEAT_S" ;;
    *)         thermal_policy="off" ;;
esac

{
    echo "# warm step-up run order"
    echo "# run_id=$RUNID"
    echo "# generated $(date -u +%Y-%m-%dT%H:%M:%SZ)  DIR=$DIR  REPEATS=$REPEATS  total=$total"
    echo "# thermal_policy: $thermal_policy   fix_clock: $FIX_CLOCK   clock_max_khz: ${CLOCK_MAX_KHZ:-base}"
    echo "$src_note"
    printf '%s\n' "${ORDER[@]}"
    echo "# per-entry run ids (group n, its run_id, the predecessor group's run_id):"
    prev="none"
    for ((i = 0; i < total; i++)); do
        echo "# order: $((i + 1)) ${IDS[$i]} prev=$prev"
        prev="${IDS[$i]}"
    done
} > "$saved_order"
echo "==> run_id=$RUNID  order ($total entries) -> $saved_order"

echo "warm step-up: PG$PGVER  DB=$DB_NAME  DIR=$DIR  BATCH_SIZES='$BATCH_SIZES'  WARMUP=$WARMUP  RUNS=$RUNS  REPEATS=$REPEATS"
echo "  thermal: $thermal_policy   fix_clock: $FIX_CLOCK (ceiling ${CLOCK_MAX_KHZ:-base freq})   batch cap: ${BATCH_CAP_SLOW:-none}"
echo "  logs -> $RUN_DIR/  ($total entries)$([ "$DRYRUN" = 1 ] && echo '   [DRY RUN]')"

if [ "$DRYRUN" = 1 ]; then
    echo "  first entries:"
    printf '    %s\n' "${ORDER[@]:0:10}"
    [ "$total" -gt 10 ] && echo "    ... ($((total - 10)) more)"
    echo "  [DRY RUN] order saved; nothing restarted or run."
    exit 0
fi

# --- 2. Clock control (optional) + system state for the summary ---------------
clock_state="$RUN_DIR/clock_state"
restore_clock(){ [ "$FIX_CLOCK" = 1 ] && bash "$HERE/clock_control.sh" restore "$clock_state"; }
export CLOCK_MAX_KHZ
trap 'echo; echo "!! interrupted"; restore_clock; exit 130' INT TERM
if [ "$FIX_CLOCK" = 1 ]; then
    bash "$HERE/clock_control.sh" apply "$clock_state"
fi
clock_lines="$(bash "$HERE/clock_control.sh" status | sed 's/^/clock_/')"
rapl_dir=/sys/class/powercap/intel-rapl/intel-rapl:0
rapl_pl1_w="n/a"; rapl_pl1_tau_s="n/a"; rapl_pl2_w="n/a"
[ -r "$rapl_dir/constraint_0_power_limit_uw" ] && rapl_pl1_w=$(awk '{printf "%.1f", $1/1e6}' "$rapl_dir/constraint_0_power_limit_uw")
[ -r "$rapl_dir/constraint_0_time_window_us" ] && rapl_pl1_tau_s=$(awk '{printf "%.2f", $1/1e6}' "$rapl_dir/constraint_0_time_window_us")
[ -r "$rapl_dir/constraint_1_power_limit_uw" ] && rapl_pl2_w=$(awk '{printf "%.1f", $1/1e6}' "$rapl_dir/constraint_1_power_limit_uw")
throttle_msgs_before=$(dmesg 2>/dev/null | grep -ci 'clock throttled\|temperature above threshold' || true)

# --- 3. The per-entry loop -----------------------------------------------------
: > "$console"
run_started=$(date +%s)
start_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ok=0; fail=0
prev_end_epoch=""
for i in "${!ORDER[@]}"; do
    qfile="${ORDER[$i]}"
    n=$((i + 1))
    rid="${IDS[$i]}"
    echo "[$n/$total] $qfile  (run_id $rid)"

    # 1. clean cold start: drop OS page cache + restart the cluster.
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || echo "  WARN: could not drop caches"
    if ! pg_ctlcluster "$PGVER" main restart >/dev/null 2>&1; then
        echo "  !! restart failed; skipping this entry"; fail=$((fail + 1)); continue
    fi
    ready=0
    for _ in $(seq 1 30); do
        [ "$(sudo -u "$DB_USER" psql -p "$PORT" -d "$DB_NAME" -tAc 'SELECT 1;' 2>/dev/null)" = "1" ] && { ready=1; break; }
        sleep 1
    done
    [ "$ready" = 1 ] || { echo "  !! $DB_NAME not ready after restart; skipping"; fail=$((fail + 1)); continue; }

    # Snapshot relation sizes once (first entry); skip it on the rest.
    skip_catalog=1; [ "$n" = 1 ] && skip_catalog=""

    # 2-4: equalise (if on) + WARMUP + step-up are query_runner's job, on this ONE file.
    echo "===== [$n/$total] $qfile run_id=$rid =====" >> "$console"
    if env ROOT="$ROOT" QUERY_DIR="$qfile" DB_NAME="$DB_NAME" DB_USER="$DB_USER" PGPORT="$PORT" \
           LOGS_DIR="$RUN_DIR" WARMUP="$WARMUP" BATCH_SIZES="$BATCH_SIZES" RUNS="$RUNS" \
           WORKERS="$WORKERS" STATEMENT_TIMEOUT="$STATEMENT_TIMEOUT" SKIP_CATALOG="$skip_catalog" \
           RUN_ID="$rid" PREV_END_EPOCH="$prev_end_epoch" \
           THERMAL_EQUALISE="$THERMAL_EQUALISE" T_LO="$T_LO" T_HI="$T_HI" \
           PREHEAT_MAX_S="$PREHEAT_MAX_S" COOLDOWN_MAX_S="$COOLDOWN_MAX_S" PREHEAT_S="$PREHEAT_S" \
           BATCH_CAP_SLOW="$BATCH_CAP_SLOW" SLOW_COPY_SEC="$SLOW_COPY_SEC" \
           "$BIN/query_runner" >> "$console" 2>&1; then
        echo "  ok"; ok=$((ok + 1))
    else
        echo "  FAILED (see $console)"; fail=$((fail + 1))
    fi
    # The runner prints when its last batch ended; the next group's idle_before_s
    # is measured from that (falls back to "now").
    prev_end_epoch=$(tail -5 "$console" | sed -n 's/^Last batch ended at epoch \([0-9.]*\).*/\1/p' | tail -1)
    [ -n "$prev_end_epoch" ] || prev_end_epoch=$(date +%s.%N)
done

restore_clock
trap - INT TERM

run_ended=$(date +%s)
dur=$((run_ended - run_started))
fmt=$(printf '%02d:%02d:%02d' $((dur / 3600)) $(((dur % 3600) / 60)) $((dur % 60)))
avg="n/a"; [ "$total" -gt 0 ] && avg="$((dur / total))s"
throttle_msgs_after=$(dmesg 2>/dev/null | grep -ci 'clock throttled\|temperature above threshold' || true)

# --- 4. summary.txt: runtime, tallies, EVERY parameter, system state ----------
# (the analysis loaders parse db:, entries:, total_runtime: - keep those lines)
{
    echo "run_id:        $RUNID"
    echo "started_utc:   $start_iso"
    echo "finished_utc:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "total_runtime: $fmt  ($dur seconds)   avg_per_entry: $avg"
    echo "entries:       $total   ok: $ok   failed: $fail"
    echo "-- parameters --"
    echo "pg:                 $PGVER"
    echo "db:                 $DB_NAME"
    echo "queries_dir:        $DIR"
    echo "queries:            $n_queries"
    echo "repeats:            $REPEATS"
    echo "batch_sizes:        $BATCH_SIZES"
    echo "runs_per_size:      $RUNS"
    echo "warmup:             $WARMUP"
    echo "batch_cap_slow:     ${BATCH_CAP_SLOW:-none} (slow_copy_sec $SLOW_COPY_SEC)"
    echo "statement_timeout:  ${STATEMENT_TIMEOUT}s"
    echo "workers:            ${WORKERS:-planner default}"
    echo "port:               $PORT"
    echo "logs_root:          $LOGS_ROOT"
    echo "run_dir:            $RUN_DIR"
    echo "order_file:         ${ORDER_FILE:-(generated)}"
    echo "saved_order:        $saved_order"
    echo "-- thermal / clock --"
    echo "thermal_policy:     $thermal_policy"
    echo "fix_clock:          $FIX_CLOCK"
    echo "clock_max_khz:      ${CLOCK_MAX_KHZ:-(base frequency)}"
    echo "$clock_lines"
    echo "rapl_pl1_w:         $rapl_pl1_w"
    echo "rapl_pl1_tau_s:     $rapl_pl1_tau_s"
    echo "rapl_pl2_w:         $rapl_pl2_w"
    echo "dmesg_throttle_msgs: $((throttle_msgs_after - throttle_msgs_before)) during run ($throttle_msgs_after total)"
} | tee "$RUN_DIR/summary.txt"

echo
echo "warm step-up done: $ok ok, $fail failed of $total entries in $fmt"
echo "  results dir: $RUN_DIR/  (query_timing_${DB_NAME}.csv, ..., summary.txt)"
echo "  order: $saved_order   console: $console"
