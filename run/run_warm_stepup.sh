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
#      the query in one psql process), warm, in the order SIZE_ORDER gives
#   5. [idle window after the last batch - OFF by default, see IDLE_AFTER_S]
#
# Steps 2-4 are query_runner (bin/query_runner) on that ONE file; this script
# owns the order, the cold start, the per-entry run ids and the run folder.
# It does NOT set the tuning GUCs: `make set-parameters` first, reset after.
#
# EACH RUN IS ISOLATED under $LOGS_ROOT/<RUNID>/ (RUNID = UTC stamp + random,
# overridable): run_order_<RUNID>.txt, query_timing_<db>.csv,
# query_samples_<db>.csv, query_catalog_<db>.csv, console.log, summary.txt.
# A run that finishes gzips its CSVs and console.log (COMPRESS_LOGS=1, the
# default: a long run's samples CSV is over GitHub's 100 MB file limit, about
# 13x smaller gzipped); run_order and summary.txt stay plain. The plain files
# are kept, moved to archive/uncompressed/<the run folder's path in the repo>/
# (git-ignored; KEEP_UNCOMPRESSED=0 deletes them instead). An interrupted run
# is left uncompressed. COMPRESS_LOGS=0 keeps everything plain in place.
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
# FIX_CLOCK BATCH_CAP_SLOW SLOW_COPY_SEC IDLE_BASELINE_S IDLE_AFTER_S
# WARMUP_FAIL_SKIP SIZE_ORDER SIZE_SEED COMPRESS_LOGS KEEP_UNCOMPRESSED DRYRUN BIN.
#
#   sudo bash run/run_warm_stepup.sh
#   sudo DRYRUN=1 bash run/run_warm_stepup.sh                  # save the order only
#   sudo ORDER_FILE=logs/warm_stepup/<RUNID>/run_order_<RUNID>.txt bash run/run_warm_stepup.sh
#
# ORDER_FILE: one entry per line, run in the order written (duplicates are
# repeats; '#' and blank lines skipped; REPEATS ignored). A line may give its
# own batch sizes after the path, comma-separated, which replace BATCH_SIZES
# for that entry only (BATCH_CAP_SLOW still applies on top):
#   queries/stackoverflow/SQLStorm/100.sql            <- BATCH_SIZES
#   queries/stackoverflow/SQLStorm/22783.sql 1,4      <- N=1 and N=4 only
# The saved run_order keeps these, so a replay runs the same sizes.
#
# SIZE_ORDER: the order of the batch sizes within each entry.
#   fixed     (default) BATCH_SIZES as written, e.g. 1 then 16
#   random    each entry its own random permutation
#   balanced  counterbalanced (Williams design): k sizes give k orders (2k when
#             k is odd) in which each size sits in each position equally often
#             and directly follows each other size equally often, so what a
#             batch carries over (heat above all) lands evenly on every size.
#             Each query starts at a random one of these orders and its repeats
#             take the next ones in turn, so a query's repeats differ and the
#             run uses every order equally often (exactly so per query when
#             REPEATS is a multiple of the number of orders).
# The chosen sizes are written into each line of the saved run_order, so a
# replay runs the same orders. Lines of an ORDER_FILE that give their own sizes
# keep them as written. SIZE_SEED makes the size orders reproducible (bash
# $RANDOM; drawn and recorded when unset); the entry order itself is shuf's.
# Each measured row records its size's position in the size_pos column.
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
IDLE_BASELINE_S="${IDLE_BASELINE_S:-0}"
IDLE_AFTER_S="${IDLE_AFTER_S:-0}"
SIZE_ORDER="${SIZE_ORDER:-fixed}"
SIZE_SEED="${SIZE_SEED:-}"
COMPRESS_LOGS="${COMPRESS_LOGS:-1}"
KEEP_UNCOMPRESSED="${KEEP_UNCOMPRESSED:-1}"
WARMUP_FAIL_SKIP="${WARMUP_FAIL_SKIP:-0}"
T_LO="${T_LO:-55}"; T_HI="${T_HI:-60}"; PREHEAT_MAX_S="${PREHEAT_MAX_S:-60}"
COOLDOWN_MAX_S="${COOLDOWN_MAX_S:-120}"; PREHEAT_S="${PREHEAT_S:-30}"
[ "$DRYRUN" = "" ] && DRYRUN=0
[ "$FIX_CLOCK" = "" ] && FIX_CLOCK=0
[ "$THERMAL_EQUALISE" = "" ] && THERMAL_EQUALISE=0
case "$SIZE_ORDER" in
    fixed|random|balanced) ;;
    *) echo "!! SIZE_ORDER=$SIZE_ORDER: expected fixed, random or balanced; aborting" >&2; exit 1 ;;
esac
if [ -n "$SIZE_SEED" ] && ! [[ "$SIZE_SEED" =~ ^[0-9]+$ ]]; then
    echo "!! SIZE_SEED=$SIZE_SEED: expected a non-negative integer; aborting" >&2; exit 1
fi

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

# A given ORDER_FILE must exist: a wrong path would otherwise fall through to a
# fresh shuffle of everything under DIR.
if [ -n "$ORDER_FILE" ] && [ ! -f "$ORDER_FILE" ]; then
    echo "!! ORDER_FILE not found: $ORDER_FILE (paths are relative to $ROOT); aborting" >&2
    exit 1
fi

RUN_DIR="$LOGS_ROOT/$RUNID"
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
# Split "<path> [<sizes>]"; SIZES[i] is empty when the line gives none.
SIZES=(); n_own=0
for i in "${!ORDER[@]}"; do
    read -r q s extra <<< "${ORDER[$i]}"
    if [ -n "$extra" ] || { [ -n "$s" ] && ! [[ "$s" =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]]; }; then
        echo "!! bad order entry $((i + 1)): '${ORDER[$i]}' (want '<query path> [<sizes> e.g. 1,4]'); aborting" >&2
        exit 1
    fi
    ORDER[$i]="$q"; SIZES[$i]="$s"
    [ -n "$s" ] && n_own=$((n_own + 1))
done
own_note=""; [ "$n_own" -gt 0 ] && own_note=" ($n_own of ${#ORDER[@]} entries set their own in the order file)"
total="${#ORDER[@]}"
n_queries=$(printf '%s\n' "${ORDER[@]}" | sort -u | grep -c .)

# Size order per entry (SIZE_ORDER), for the entries that give no sizes of their own.
read -ra BASE_SIZES <<< "${BATCH_SIZES//,/ }"
k=${#BASE_SIZES[@]}
size_note="fixed"
if [ "$SIZE_ORDER" != fixed ] && [ "$k" -lt 2 ]; then
    echo "  note: SIZE_ORDER=$SIZE_ORDER needs two or more BATCH_SIZES; running them fixed"
    SIZE_ORDER=fixed
fi
if [ "$SIZE_ORDER" != fixed ]; then
    [ -n "$SIZE_SEED" ] || SIZE_SEED=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
    RANDOM=$SIZE_SEED
    SEQS=()                       # the balanced design: one "i j ..." index list per order
    if [ "$SIZE_ORDER" = balanced ]; then
        base=()                   # Williams first row: 0 1 k-1 2 k-2 ...
        for ((j = 0; j < k; j++)); do
            if ((j == 0)); then base+=(0); elif ((j % 2)); then base+=($(((j + 1) / 2))); else base+=($((k - j / 2))); fi
        done
        for ((r = 0; r < k; r++)); do
            row=(); for b in "${base[@]}"; do row+=($(((b + r) % k))); done
            SEQS+=("${row[*]}")
        done
        if ((k % 2)); then        # odd k: the reversed rows complete the carry-over balance
            for ((r = 0; r < k; r++)); do
                read -ra row <<< "${SEQS[$r]}"; rev=()
                for ((j = k - 1; j >= 0; j--)); do rev+=("${row[$j]}"); done
                SEQS+=("${rev[*]}")
            done
        fi
    fi
    m=${#SEQS[@]}
    declare -A Q_OFF=() Q_OCC=()
    n_perm=0
    for i in "${!ORDER[@]}"; do
        [ -n "${SIZES[$i]}" ] && continue
        if [ "$SIZE_ORDER" = balanced ]; then
            q="${ORDER[$i]}"
            [ -n "${Q_OFF[$q]+x}" ] || { Q_OFF[$q]=$((RANDOM % m)); Q_OCC[$q]=0; }
            read -ra idx <<< "${SEQS[$(((Q_OFF[$q] + Q_OCC[$q]) % m))]}"
            Q_OCC[$q]=$((Q_OCC[$q] + 1))
        else
            idx=(); for ((j = 0; j < k; j++)); do idx+=("$j"); done
            for ((j = k - 1; j > 0; j--)); do r=$((RANDOM % (j + 1))); t=${idx[$j]}; idx[$j]=${idx[$r]}; idx[$r]=$t; done
        fi
        out=""; for j in "${idx[@]}"; do out+="${out:+,}${BASE_SIZES[$j]}"; done
        SIZES[$i]="$out"; n_perm=$((n_perm + 1))
    done
    size_note="$SIZE_ORDER seed=$SIZE_SEED"
    [ "$SIZE_ORDER" = balanced ] && size_note+=" ($m orders)"
    size_note+=" on $n_perm of $total entries"
elif [ -n "$ORDER_FILE" ]; then
    replayed=$(grep -m1 '^# size_order:' "$ORDER_FILE" | sed 's/^# size_order: *//')
    [ -n "$replayed" ] && size_note="as in the order file (made with: $replayed)"
fi
# How often each size ran at each position: the check that the order is balanced.
size_table(){
    declare -A cnt=(); local i j sz maxp=0
    for i in "${!ORDER[@]}"; do
        IFS=', ' read -ra row <<< "${SIZES[$i]:-$BATCH_SIZES}"
        for j in "${!row[@]}"; do cnt["${row[$j]},$j"]=$((${cnt["${row[$j]},$j"]:-0} + 1)); ((j + 1 > maxp)) && maxp=$((j + 1)); done
    done
    printf '  size x position:'; for ((j = 1; j <= maxp; j++)); do printf ' %8s' "pos$j"; done; echo
    for sz in $(printf '%s\n' "${!cnt[@]}" | cut -d, -f1 | sort -un); do
        printf '  %16s' "N=$sz"; for ((j = 0; j < maxp; j++)); do printf ' %8s' "${cnt["$sz,$j"]:-0}"; done; echo
    done
}

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

mkdir -p "$RUN_DIR"
{
    echo "# warm step-up run order"
    echo "# run_id=$RUNID"
    echo "# generated $(date -u +%Y-%m-%dT%H:%M:%SZ)  DIR=$DIR  REPEATS=$REPEATS  total=$total"
    echo "# thermal_policy: $thermal_policy   fix_clock: $FIX_CLOCK   clock_max_khz: ${CLOCK_MAX_KHZ:-base}"
    echo "# size_order: $size_note   batch_sizes: $BATCH_SIZES"
    echo "$src_note"
    for ((i = 0; i < total; i++)); do echo "${ORDER[$i]}${SIZES[$i]:+ ${SIZES[$i]}}"; done
    echo "# per-entry run ids (group n, its run_id, the predecessor group's run_id):"
    prev="none"
    for ((i = 0; i < total; i++)); do
        echo "# order: $((i + 1)) ${IDS[$i]} prev=$prev"
        prev="${IDS[$i]}"
    done
} > "$saved_order"
echo "==> run_id=$RUNID  order ($total entries) -> $saved_order"

echo "warm step-up: PG$PGVER  DB=$DB_NAME  DIR=$DIR  BATCH_SIZES='$BATCH_SIZES'$own_note  WARMUP=$WARMUP  RUNS=$RUNS  REPEATS=$REPEATS"
echo "  thermal: $thermal_policy   fix_clock: $FIX_CLOCK (ceiling ${CLOCK_MAX_KHZ:-base freq})   batch cap: ${BATCH_CAP_SLOW:-none}"
echo "  size order: $size_note   idle before/after: ${IDLE_BASELINE_S}s / ${IDLE_AFTER_S}s"
[ "$SIZE_ORDER" != fixed ] && size_table
echo "  logs -> $RUN_DIR/  ($total entries)$([ "$DRYRUN" = 1 ] && echo '   [DRY RUN]')"

if [ "$DRYRUN" = 1 ]; then
    echo "  first entries:"
    for ((i = 0; i < total && i < 10; i++)); do echo "    ${ORDER[$i]}${SIZES[$i]:+ ${SIZES[$i]}}"; done
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
node_lines="$(bash "$HERE/node_info.sh")"     # as the run sees it (clock applied)
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
    sizes="${SIZES[$i]:-$BATCH_SIZES}"
    echo "[$n/$total] $qfile  (run_id $rid)${SIZES[$i]:+  sizes ${SIZES[$i]}}"

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
    echo "===== [$n/$total] $qfile run_id=$rid sizes=$sizes =====" >> "$console"
    if env ROOT="$ROOT" QUERY_DIR="$qfile" DB_NAME="$DB_NAME" DB_USER="$DB_USER" PGPORT="$PORT" \
           LOGS_DIR="$RUN_DIR" WARMUP="$WARMUP" BATCH_SIZES="$sizes" RUNS="$RUNS" \
           WORKERS="$WORKERS" STATEMENT_TIMEOUT="$STATEMENT_TIMEOUT" SKIP_CATALOG="$skip_catalog" \
           RUN_ID="$rid" PREV_END_EPOCH="$prev_end_epoch" \
           THERMAL_EQUALISE="$THERMAL_EQUALISE" T_LO="$T_LO" T_HI="$T_HI" \
           PREHEAT_MAX_S="$PREHEAT_MAX_S" COOLDOWN_MAX_S="$COOLDOWN_MAX_S" PREHEAT_S="$PREHEAT_S" \
           BATCH_CAP_SLOW="$BATCH_CAP_SLOW" SLOW_COPY_SEC="$SLOW_COPY_SEC" \
           IDLE_BASELINE_S="$IDLE_BASELINE_S" IDLE_AFTER_S="$IDLE_AFTER_S" WARMUP_FAIL_SKIP="$WARMUP_FAIL_SKIP" \
           RAPL_OPTIONAL="${RAPL_OPTIONAL:-}" RAPL_BACKEND="${RAPL_BACKEND:-}" \
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
    echo "batch_sizes:        $BATCH_SIZES$own_note"
    echo "size_order:         $size_note"
    echo "runs_per_size:      $RUNS"
    echo "warmup:             $WARMUP"
    echo "batch_cap_slow:     ${BATCH_CAP_SLOW:-none} (slow_copy_sec $SLOW_COPY_SEC)"
    echo "statement_timeout:  ${STATEMENT_TIMEOUT}s"
    echo "idle_baseline_s:    $IDLE_BASELINE_S"
    echo "idle_after_s:       $IDLE_AFTER_S"
    echo "warmup_fail_skip:   $WARMUP_FAIL_SKIP"
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
    echo "-- node --"
    echo "$node_lines"
} | tee "$RUN_DIR/summary.txt"

# --- 5. gzip the big files (COMPRESS_LOGS) --------------------------------------
# gzip -k writes <file>.gz next to it; only once that succeeded is the plain
# file moved to the archive (or deleted with KEEP_UNCOMPRESSED=0). A file it
# cannot compress stays as it is. The archive mirrors the run folder's path in
# the repo (archive/uncompressed/logs/warm_stepup/<RUNID>/); a run folder
# outside the repo uses archive/uncompressed/<RUNID>/.
ext=""
if [ "$COMPRESS_LOGS" = 1 ]; then
    run_abs="$(cd "$RUN_DIR" && pwd)"
    case "$run_abs/" in
        "$ROOT"/*) keep_dir="$ROOT/archive/uncompressed/${run_abs#"$ROOT"/}" ;;
        *)         keep_dir="$ROOT/archive/uncompressed/$RUNID" ;;
    esac
    before=$(du -sk "$RUN_DIR" | cut -f1)
    for f in "$RUN_DIR"/*.csv "$console"; do
        [ -f "$f" ] || continue
        if ! gzip -6 -k "$f"; then
            echo "  WARN: could not gzip $f; left as it is"; rm -f "$f.gz"; continue
        fi
        touch -r "$f" "$f.gz"
        if [ "$KEEP_UNCOMPRESSED" = 0 ]; then
            rm -f "$f"
        else
            mkdir -p "$keep_dir" && mv "$f" "$keep_dir/" || echo "  WARN: could not move $f to $keep_dir; left in place"
        fi
    done
    after=$(du -sk "$RUN_DIR" | cut -f1)
    awk -v b="$before" -v a="$after" 'BEGIN { printf "  compressed: %.1f MB -> %.1f MB (CSVs and console.log gzipped)\n", b / 1024, a / 1024 }'
    [ "$KEEP_UNCOMPRESSED" != 0 ] && [ -d "$keep_dir" ] && echo "  plain copies kept in ${keep_dir#"$ROOT"/}/ (git-ignored)"
    ext=".gz"
fi

echo
echo "warm step-up done: $ok ok, $fail failed of $total entries in $fmt"
echo "  results dir: $RUN_DIR/  (query_timing_${DB_NAME}.csv$ext, ..., summary.txt)"
echo "  order: $saved_order   console: $console$ext"
