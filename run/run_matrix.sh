#!/usr/bin/env bash
#
# run_matrix.sh - the warm step-up benchmark across PostgreSQL versions x
# databases, unattended (`make matrix`, `make matrix-plan`).
#
# Every (version, database) combination is ONE run_warm_stepup.sh run - the
# same per-query cold start + WARMUP + BATCH_SIZES step-up, REPEATS times in a
# random order - into its own folder $LOGS_ROOT/pg<ver>_<db>_<stamp>/ (default
# LOGS_ROOT = $LOGS_DIR/matrix). So a matrix result is exactly a set of
# warm-stepup results, readable by the same tooling.
#
#   sudo bash run/run_matrix.sh                       # PGVERS x DBS
#   sudo PGVERS=18 DBS="tpch tpch_idx" bash run/run_matrix.sh
#   sudo DRYRUN=1 bash run/run_matrix.sh              # plan + ETA, run nothing
#
# Built to survive a night alone:
#   * ONE COMBINATION FAILING DOES NOT STOP THE SWEEP (no set -e).
#   * RESUMABLE: finished combinations go into a manifest and are skipped next
#     time (FRESH=1 ignores it).
#   * STATEMENT_TIMEOUT caps every execution server-side.
#   * Ctrl-C reports what finished.
# Console logs: $MATRIX_DIR/pg<ver>_<db>.log per combination + matrix.log.
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"                 # repo root (this script lives in run/)
cd "$ROOT" || exit 1

PGVERS="${PGVERS:-15 16 17 18}"
DBS="${DBS:-tpch tpch_idx}"
DIR="${DIR:-queries/tpch/tpch-queries}"
REPEATS="${REPEATS:-1}"
WARMUP="${WARMUP:-2}"
BATCH_SIZES="${BATCH_SIZES:-1 16}"
RUNS="${RUNS:-1}"
WORKERS="${WORKERS:-}"
STATEMENT_TIMEOUT="${STATEMENT_TIMEOUT:-900}"
LOGS_DIR="${LOGS_DIR:-logs}"
LOGS_ROOT="${LOGS_ROOT:-$LOGS_DIR/matrix}"
MATRIX_DIR="${MATRIX_DIR:-matrix_logs}"
DRYRUN="${DRYRUN:-0}"; [ "$DRYRUN" = "" ] && DRYRUN=0
FRESH="${FRESH:-0}"
# Per-entry cold start overhead (cache drop + restart + ready wait), seconds.
RESTART_SEC="${RESTART_SEC:-10}"
# Measured on this machine: one execution of every query in the 53-file
# tpch-queries set at SF1 costs ~0.49 h / 53 queries. Only for the estimate.
HOURS_PER_PASS_SF1="${HOURS_PER_PASS_SF1:-0.49}"
REFERENCE_QUERIES="${REFERENCE_QUERIES:-53}"

MANIFEST="$MATRIX_DIR/completed.tsv"
MASTER_LOG="$MATRIX_DIR/matrix.log"
mkdir -p "$MATRIX_DIR"
[ "$FRESH" = "1" ] && rm -f "$MANIFEST"
touch "$MANIFEST"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$MASTER_LOG"; }
port_of() { pg_lsclusters -h 2>/dev/null | awk -v v="$1" '$1 == v && $2 == "main" { print $3 }'; }
db_exists() { [ "$(sudo -u postgres psql -p "$1" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$2'" 2>/dev/null)" = "1" ]; }
sf_of() { local n="${1#tpch}"; n="${n%_idx}"; echo "${n:-1}"; }   # tpch -> 1, tpch5_idx -> 5
done_already() { grep -qP "^$1\t$2\t" "$MANIFEST" 2>/dev/null; }
fmt_hms() { printf '%dh%02dm%02ds' $(($1/3600)) $(($1%3600/60)) $(($1%60)); }

# --- estimate -----------------------------------------------------------------
if [ -f "$DIR" ]; then DIR_QUERIES=1; else DIR_QUERIES=$(find "$DIR" -name '*.sql' 2>/dev/null | wc -l); fi
sum_sizes=0; for s in $BATCH_SIZES; do sum_sizes=$((sum_sizes + s)); done
EXEC_PER_ENTRY=$((WARMUP + RUNS * sum_sizes))
ENTRIES=$((DIR_QUERIES * REPEATS))
HOURS_PER_EXEC_SF1=$(awk -v h="$HOURS_PER_PASS_SF1" -v r="$REFERENCE_QUERIES" 'BEGIN{printf "%.8f", h / r}')
combo_hours() {   # sf
    awk -v he="$HOURS_PER_EXEC_SF1" -v e="$ENTRIES" -v x="$EXEC_PER_ENTRY" -v s="$1" -v rs="$RESTART_SEC" \
        'BEGIN{printf "%.2f", he*x*e*s + e*rs/3600.0}'
}

# --- plan ---------------------------------------------------------------------
COMBOS=(); SKIPPED=(); TOTAL_HOURS=0
for db in $DBS; do
    for ver in $PGVERS; do
        port="$(port_of "$ver")"
        if [ -z "$port" ]; then SKIPPED+=("PG$ver/$db  (no cluster for PostgreSQL $ver)"); continue; fi
        if ! db_exists "$port" "$db"; then SKIPPED+=("PG$ver/$db  (database absent on port $port)"); continue; fi
        if [ "$FRESH" != "1" ] && done_already "$ver" "$db"; then SKIPPED+=("PG$ver/$db  (already done - FRESH=1 to redo)"); continue; fi
        COMBOS+=("$ver:$db:$port")
        TOTAL_HOURS=$(awk -v t="$TOTAL_HOURS" -v c="$(combo_hours "$(sf_of "$db")")" 'BEGIN{printf "%.2f", t + c}')
    done
done

echo
echo "============================ MATRIX PLAN ============================"
printf '  queries      %s  (%s .sql x REPEATS=%s = %s entries per combination)\n' "$DIR" "$DIR_QUERIES" "$REPEATS" "$ENTRIES"
[ "$DIR_QUERIES" -eq 0 ] && echo "  WARNING: no .sql files under $DIR - nothing will run"
printf '  per entry    cold start + %s warmup + step-up %s x%s  (%s executions)\n' "$WARMUP" "$BATCH_SIZES" "$RUNS" "$EXEC_PER_ENTRY"
printf '  workers      %s\n  timeout      %ss per execution\n  thermal      equalise=%s fix_clock=%s\n' \
       "${WORKERS:-planner default}" "$STATEMENT_TIMEOUT" "${THERMAL_EQUALISE:-0}" "${FIX_CLOCK:-0}"
printf '  output       %s/pg<ver>_<db>_<stamp>/\n' "$LOGS_ROOT"
echo
if [ ${#COMBOS[@]} -eq 0 ]; then echo "  nothing to run"; else
    echo "  to run, in order:"
    for c in "${COMBOS[@]}"; do
        IFS=: read -r v d p <<< "$c"
        printf '    PG%-3s %-10s (port %s)  ~%s h\n' "$v" "$d" "$p" "$(combo_hours "$(sf_of "$d")")"
    done
fi
if [ ${#SKIPPED[@]} -gt 0 ]; then echo; echo "  skipped:"; printf '    %s\n' "${SKIPPED[@]}"; fi
echo
printf '  ESTIMATED TOTAL: %s h  (finishes ~%s)\n' "$TOTAL_HOURS" \
       "$(date -d "+${TOTAL_HOURS%.*} hours" '+%a %H:%M' 2>/dev/null || echo '?')"
echo "====================================================================="
echo

[ "$DRYRUN" = "1" ] && { echo "DRYRUN=1, stopping here."; exit 0; }
[ ${#COMBOS[@]} -eq 0 ] && exit 0

# --- run ----------------------------------------------------------------------
FINISHED=0; FAILED=0; START_ALL=$(date +%s)
on_interrupt() {
    echo
    log "INTERRUPTED after $FINISHED/${#COMBOS[@]} combinations ($(fmt_hms $(($(date +%s) - START_ALL))) elapsed)"
    log "Re-run the same command to resume; completed combinations are skipped."
    exit 130
}
trap on_interrupt INT TERM

log "matrix start: ${#COMBOS[@]} combinations, estimated ${TOTAL_HOURS}h"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)

for c in "${COMBOS[@]}"; do
    IFS=: read -r ver db port <<< "$c"
    combo_log="$MATRIX_DIR/pg${ver}_${db}.log"
    runid="pg${ver}_${db}_${STAMP}"
    log "[$((FINISHED + FAILED + 1))/${#COMBOS[@]}] START PG$ver $db (port $port) -> $LOGS_ROOT/$runid/  (console: $combo_log)"
    t0=$(date +%s)

    env DIR="$DIR" REPEATS="$REPEATS" WARMUP="$WARMUP" BATCH_SIZES="$BATCH_SIZES" RUNS="$RUNS" \
        DB_NAME="$db" PGVER="$ver" LOGS_ROOT="$LOGS_ROOT" RUNID="$runid" \
        WORKERS="$WORKERS" STATEMENT_TIMEOUT="$STATEMENT_TIMEOUT" \
        THERMAL_EQUALISE="${THERMAL_EQUALISE:-0}" T_LO="${T_LO:-55}" T_HI="${T_HI:-60}" \
        PREHEAT_MAX_S="${PREHEAT_MAX_S:-60}" COOLDOWN_MAX_S="${COOLDOWN_MAX_S:-120}" PREHEAT_S="${PREHEAT_S:-30}" \
        FIX_CLOCK="${FIX_CLOCK:-0}" BATCH_CAP_SLOW="${BATCH_CAP_SLOW:-}" SLOW_COPY_SEC="${SLOW_COPY_SEC:-1}" \
        BIN="${BIN:-$ROOT/bin}" \
        bash "$HERE/run_warm_stepup.sh" > "$combo_log" 2>&1
    rc=$?
    dt=$(($(date +%s) - t0))

    # Entry-level failures are counted in the summary; a non-zero rc means the
    # driver itself broke (no cluster, no queries, ...).
    efail=$(sed -n 's/^entries: *[0-9]* *ok: *[0-9]* *failed: *\([0-9]*\).*/\1/p' "$LOGS_ROOT/$runid/summary.txt" 2>/dev/null)
    efail=${efail:-?}
    if [ $rc -eq 0 ]; then
        FINISHED=$((FINISHED + 1))
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ver" "$db" "$(date -Iseconds)" "$dt" "$efail" "$runid" >> "$MANIFEST"
        log "    OK   PG$ver $db in $(fmt_hms $dt) ($efail entry failures) -> $LOGS_ROOT/$runid/"
    else
        FAILED=$((FAILED + 1))
        log "    FAIL PG$ver $db after $(fmt_hms $dt) (exit $rc) - see $combo_log"
        tail -3 "$combo_log" | sed 's/^/         /' | tee -a "$MASTER_LOG"
    fi
done

echo | tee -a "$MASTER_LOG"
log "MATRIX DONE in $(fmt_hms $(($(date +%s) - START_ALL))): $FINISHED ok, $FAILED failed"
echo
echo "=========================== RESULT FOLDERS ==========================="
for d in "$LOGS_ROOT"/pg*_"$STAMP"; do
    [ -d "$d" ] || continue
    printf '  %-50s %s\n' "$d" "$(sed -n 's/^total_runtime: *\(.*\)/\1/p' "$d/summary.txt" 2>/dev/null)"
done
echo "======================================================================"
