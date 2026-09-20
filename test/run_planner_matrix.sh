#!/usr/bin/env bash
#
# run_planner_matrix.sh - sweep planner_consistency.sh across PostgreSQL
# versions x TPC-H sizes, automated.
#
# planner_consistency.sh itself stays single-version/single-db and untouched
# in its own logic; this just calls it once per (version, db) combination
# with its own isolated output folder, so nothing overwrites anything else.
#
#   sudo COLD_SCRIPT=./my_cache_drop.sh bash run_planner_matrix.sh
#   sudo COLD_SCRIPT=./my_cache_drop.sh PGVERS=18 DBS="tpch tpch2" bash run_planner_matrix.sh
#   sudo BATCHNUM=4 bash run_planner_matrix.sh         # 4 concurrent copies/pass
#   sudo DRYRUN=1 bash run_planner_matrix.sh           # print the plan, run nothing
#   sudo FRESH=1 bash run_planner_matrix.sh            # ignore the manifest, redo everything
#

# Then check progress any time with: tail -f planner_matrix_logs/matrix.log
#
# RESUMABLE, like run_matrix.sh: completed (version, db) combinations are
# appended to a manifest and skipped on the next invocation, so an
# interrupted night can simply be re-run instead of starting over. FRESH=1
# ignores the manifest and redoes everything.
#
# ONE COMBINATION FAILING DOES NOT STOP THE SWEEP - each is logged and the
# next one runs regardless.
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"          # repo root
cd "$ROOT"

PGVERS="${PGVERS:-16 18}"
DBS="${DBS:-tpch tpch2 tpch5}"
STATES="${STATES:-cold warm}"
RUNS="${RUNS:-10}"
WARMUP="${WARMUP:-2}"
BATCHNUM="${BATCHNUM:-1}"
COLD_EACH_QUERY="${COLD_EACH_QUERY:-1}"
STATEMENT_TIMEOUT="${STATEMENT_TIMEOUT:-900}"
DIR="${DIR:-queries/equivalent/tpch}"
COLD_SCRIPT="${COLD_SCRIPT:-}"
BASE_OUT="${BASE_OUT:-planner_matrix_logs}"
SCRIPT="${SCRIPT:-$HERE/planner_consistency.sh}"
DRYRUN="${DRYRUN:-0}"
FRESH="${FRESH:-0}"

MANIFEST="$BASE_OUT/completed.tsv"
MASTER_LOG="$BASE_OUT/matrix.log"
mkdir -p "$BASE_OUT"
[ "$FRESH" = "1" ] && rm -f "$MANIFEST"
touch "$MANIFEST"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$MASTER_LOG"; }

fmt_hms() { printf '%dh%02dm%02ds' $(($1/3600)) $(($1%3600/60)) $(($1%60)); }

done_already() { grep -qP "^$1\t$2\t" "$MANIFEST" 2>/dev/null; }

if [ ! -f "$SCRIPT" ]; then
    echo "!! cannot find planner_consistency.sh at $SCRIPT (set SCRIPT= if it lives elsewhere)" >&2
    exit 1
fi
if [ -z "$COLD_SCRIPT" ] && [[ "$STATES" == *cold* ]]; then
    echo "!! COLD_SCRIPT is not set but STATES includes 'cold'. Aborting." >&2
    exit 1
fi

COMBOS=()
SKIPPED=()
for ver in $PGVERS; do
    for db in $DBS; do
        if [ "$FRESH" != "1" ] && done_already "$ver" "$db"; then
            SKIPPED+=("PG$ver/$db  (already done - FRESH=1 to redo)")
        else
            COMBOS+=("$ver:$db")
        fi
    done
done

echo
echo "========================= PLANNER MATRIX PLAN ========================="
printf '  versions     %s\n' "$PGVERS"
printf '  databases    %s\n' "$DBS"
printf '  states       %s\n' "$STATES"
printf '  passes       %s per state, per combination\n' "$RUNS"
printf '  batchnum     %s %s\n' "$BATCHNUM" "$([ "$BATCHNUM" -gt 1 ] && echo '(concurrent copies per pass)' || echo '(one copy at a time)')"
printf '  combinations %s to run, %s already done\n' "${#COMBOS[@]}" "${#SKIPPED[@]}"
printf '  output       %s/pg<version>_<db>/\n' "$BASE_OUT"
echo
if [ ${#COMBOS[@]} -eq 0 ]; then
    echo "  nothing to run"
else
    echo "  to run, in order:"
    for c in "${COMBOS[@]}"; do
        IFS=: read -r v d <<< "$c"
        printf '    PG%-3s %-8s -> %s/pg%s_%s/\n' "$v" "$d" "$BASE_OUT" "$v" "$d"
    done
fi
if [ ${#SKIPPED[@]} -gt 0 ]; then
    echo
    echo "  skipped:"
    printf '    %s\n' "${SKIPPED[@]}"
fi
echo "=========================================================================="
echo

[ "$DRYRUN" = "1" ] && { echo "DRYRUN=1, stopping here."; exit 0; }
[ ${#COMBOS[@]} -eq 0 ] && exit 0

FINISHED=0
FAILED=0
START_ALL=$(date +%s)

on_interrupt() {
    echo
    log "INTERRUPTED after $FINISHED ok / $FAILED failed of ${#COMBOS[@]} combinations"
    log "Re-run the same command to resume; completed combinations are skipped."
    exit 130
}
trap on_interrupt INT TERM

log "matrix start: ${#COMBOS[@]} combinations"

for c in "${COMBOS[@]}"; do
    IFS=: read -r ver db <<< "$c"
    combo_out="$BASE_OUT/pg${ver}_${db}"
    mkdir -p "$combo_out"
    log "[$((FINISHED + FAILED + 1))/${#COMBOS[@]}] START PG$ver $db -> $combo_out"
    t0=$(date +%s)

    PGVER="$ver" DB="$db" DIR="$DIR" STATES="$STATES" RUNS="$RUNS" \
        WARMUP="$WARMUP" BATCHNUM="$BATCHNUM" COLD_EACH_QUERY="$COLD_EACH_QUERY" \
        STATEMENT_TIMEOUT="$STATEMENT_TIMEOUT" COLD_SCRIPT="$COLD_SCRIPT" \
        OUT_DIR="$combo_out" \
        bash "$SCRIPT" >> "$combo_out/wrapper_stdout.log" 2>&1
    rc=$?
    dt=$(($(date +%s) - t0))

    if [ $rc -eq 0 ]; then
        FINISHED=$((FINISHED + 1))
        printf '%s\t%s\t%s\t%s\n' "$ver" "$db" "$(date -Iseconds)" "$dt" >> "$MANIFEST"
        log "    OK   PG$ver $db in $(fmt_hms $dt)"
    else
        FAILED=$((FAILED + 1))
        log "    FAIL PG$ver $db after $(fmt_hms $dt) (exit $rc) - see $combo_out/wrapper_stdout.log"
        tail -5 "$combo_out/wrapper_stdout.log" | sed 's/^/         /' | tee -a "$MASTER_LOG"
    fi
done

echo | tee -a "$MASTER_LOG"
log "MATRIX DONE in $(fmt_hms $(($(date +%s) - START_ALL))): $FINISHED ok, $FAILED failed"
echo
echo "=========================== COMBINED DRIFT SUMMARY ==========================="
awk -F, 'FNR==1{next} {key=FILENAME"|"$2"|"$5; shapes[key]=shapes[key]" "$11} END {
    for (k in shapes) {
        n=split(shapes[k], arr, " ");
        delete seen;
        distinct=0;
        for (i=1;i<=n;i++) if (!seen[arr[i]]++) distinct++;
        split(k, parts, "|");
        if (distinct > 1) printf "  DRIFT   %-45s state=%-5s query=%-15s %d distinct plan shapes across %d runs\n", parts[1], parts[2], parts[3], distinct, n;
    }
}' "$BASE_OUT"/pg*_*/consistency_pg*.csv 2>/dev/null
echo
echo "  (no DRIFT lines above = every combination's plans were consistent)"
echo "  per-combination data: $BASE_OUT/pg<version>_<db>/consistency_pg<version>_<db>.csv"
echo "==================================================================================="