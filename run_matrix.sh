#!/usr/bin/env bash
#
# run_matrix.sh - sweep the read benchmark across PostgreSQL versions x database
# sizes, unattended.
#
# Every combination is one ordinary `make run`, so the per-database CSVs stay
# exactly as they are; because every row carries pg_version, all three majors
# share one file per database and are still told apart.
#
#   sudo bash run_matrix.sh                    # all versions x all sizes
#   sudo PGVERS=16 bash run_matrix.sh          # one version, all sizes
#   sudo DBS="tpch tpch2" bash run_matrix.sh   # all versions, two sizes
#   sudo DRYRUN=1 bash run_matrix.sh           # print the plan + ETA, run nothing
#
# Designed to survive a night alone:
#   * ONE COMBINATION FAILING DOES NOT STOP THE RUN. set -e is deliberately not
#     used; a bad combination is recorded and the sweep moves to the next.
#   * RESUMABLE. Completed combinations are appended to a manifest and skipped
#     on the next invocation, so an interrupted night can simply be re-run.
#     FRESH=1 ignores the manifest and redoes everything.
#   * A PER-QUERY TIMEOUT is on by default (STATEMENT_TIMEOUT seconds). The
#     server cancels the query, the runner logs a failure and continues. Without
#     it a single pathological query can eat the whole night - which is exactly
#     what the queries in ./slow_queries do, and why ./queries excludes them.
#   * Ctrl-C reports what was finished before exiting.
#
# Everything is logged: matrix_logs/<pgver>_<db>.log per combination, plus
# matrix_logs/matrix.log for the run as a whole.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

PGVERS="${PGVERS:-14 16 18}"
DBS="${DBS:-tpch tpch2 tpch5}"
RUNS="${RUNS:-3}"
WARMUP="${WARMUP:-2}"
BATCHNUM="${BATCHNUM:-1}"
DIR="${DIR:-queries}"
WORKERS="${WORKERS:-}"
STATEMENT_TIMEOUT="${STATEMENT_TIMEOUT:-900}"
MATRIX_DIR="${MATRIX_DIR:-matrix_logs}"
DRYRUN="${DRYRUN:-0}"
FRESH="${FRESH:-0}"

MANIFEST="$MATRIX_DIR/completed.tsv"
MASTER_LOG="$MATRIX_DIR/matrix.log"

# Measured on this machine: one execution pass over the full ./queries corpus at
# SF1 costs ~0.49 h (one execution of each query). Cost scales ~linearly with the
# scale factor (corpus is scan-dominated) and, below, with how many queries DIR
# actually holds. Used only for the up-front estimate - override if HW differs.
HOURS_PER_PASS_SF1="${HOURS_PER_PASS_SF1:-0.49}"

# Query executions (copies) per query, which the runtime scales with.
if [ "$BATCHNUM" -gt 1 ]; then
    # WARMUP single copies (warm ones anchor N=1) + RUNS batches at BATCHNUM.
    EXEC_PER_QUERY=$(( WARMUP + RUNS * BATCHNUM ))
else
    EXEC_PER_QUERY=$(( WARMUP + RUNS ))
fi

# DIR scaling. HOURS_PER_PASS_SF1 is a FULL-corpus pass; a subdirectory runs
# proportionally fewer queries, so scale by (queries under DIR / full corpus).
# The per-query cost is the pass cost divided by the reference corpus size, both
# counted as .sql files. ROUGH: assumes ~uniform per-query cost, which isn't
# exact (a few math queries dominate), so a subset figure is an approximation.
REFERENCE_DIR="${REFERENCE_DIR:-queries}"
REFERENCE_QUERIES="${REFERENCE_QUERIES:-$(find "$REFERENCE_DIR" -name '*.sql' 2>/dev/null | wc -l)}"
DIR_QUERIES=$(find "$DIR" -name '*.sql' 2>/dev/null | wc -l)
[ "${REFERENCE_QUERIES:-0}" -gt 0 ] 2>/dev/null || REFERENCE_QUERIES=1
HOURS_PER_QUERY_SF1=$(awk -v h="$HOURS_PER_PASS_SF1" -v r="$REFERENCE_QUERIES" \
                          'BEGIN{printf "%.8f", h / r}')

mkdir -p "$MATRIX_DIR"
[ "$FRESH" = "1" ] && rm -f "$MANIFEST"
touch "$MANIFEST"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$MASTER_LOG"; }

port_of() { pg_lsclusters -h 2>/dev/null | awk -v v="$1" '$1 == v && $2 == "main" { print $3 }'; }

db_exists() {   # port, db
    [ "$(sudo -u postgres psql -p "$1" -d postgres -tAc \
         "SELECT 1 FROM pg_database WHERE datname='$2'" 2>/dev/null)" = "1" ]
}

# "tpch" -> 1, "tpch2" -> 2, "tpch5" -> 5. Only used for the time estimate.
sf_of() { local n="${1#tpch}"; echo "${n:-1}"; }

done_already() { grep -qP "^$1\t$2\t" "$MANIFEST" 2>/dev/null; }

fmt_hms() { printf '%dh%02dm%02ds' $(($1/3600)) $(($1%3600/60)) $(($1%60)); }

# ------------------------------------------------------------------ plan
# Sizes ascending so an interrupted night still finishes the cheap
# combinations; versions grouped inside each size.
COMBOS=()
SKIPPED=()
TOTAL_HOURS=0
for db in $(for d in $DBS; do echo "$(sf_of "$d") $d"; done | sort -n | awk '{print $2}'); do
    for ver in $PGVERS; do
        port="$(port_of "$ver")"
        if [ -z "$port" ]; then
            SKIPPED+=("PG$ver/$db  (no cluster for PostgreSQL $ver)"); continue
        fi
        if ! db_exists "$port" "$db"; then
            SKIPPED+=("PG$ver/$db  (database absent on port $port)"); continue
        fi
        if [ "$FRESH" != "1" ] && done_already "$ver" "$db"; then
            SKIPPED+=("PG$ver/$db  (already done - FRESH=1 to redo)"); continue
        fi
        COMBOS+=("$ver:$db:$port")
        TOTAL_HOURS=$(awk -v t="$TOTAL_HOURS" -v hq="$HOURS_PER_QUERY_SF1" \
                          -v dq="$DIR_QUERIES" -v p="$EXEC_PER_QUERY" -v s="$(sf_of "$db")" \
                          'BEGIN{printf "%.2f", t + hq*dq*p*s}')
    done
done

echo
echo "============================ MATRIX PLAN ============================"
FRAC=$(awk -v d="$DIR_QUERIES" -v r="$REFERENCE_QUERIES" 'BEGIN{printf "%.1f", d*100.0/r}')
printf '  queries      %s  (%s of %s .sql = %s%% of the %s corpus)\n' \
       "$DIR" "$DIR_QUERIES" "$REFERENCE_QUERIES" "$FRAC" "$REFERENCE_DIR"
[ "$DIR_QUERIES" -eq 0 ] && echo "  WARNING: no .sql files under $DIR - estimate is 0 and nothing will run"
if [ "$BATCHNUM" -gt 1 ]; then
    printf '  mode         slope: %s batches at N=%s, %s single-copy warmups (warm ones anchor N=1)  (%s executions/query)\n' \
           "$RUNS" "$BATCHNUM" "$WARMUP" "$EXEC_PER_QUERY"
else
    printf '  mode         single-size: %s runs, %s single-copy warmups  (%s executions/query)\n' \
           "$RUNS" "$WARMUP" "$EXEC_PER_QUERY"
fi
printf '  workers      %s\n  timeout      %ss per query\n' \
       "${WORKERS:-planner default}" "$STATEMENT_TIMEOUT"
echo
if [ ${#COMBOS[@]} -eq 0 ]; then
    echo "  nothing to run"
else
    echo "  to run, in order:"
    for c in "${COMBOS[@]}"; do
        IFS=: read -r v d p <<< "$c"
        printf '    PG%-3s %-7s (port %s)  ~%.1f h\n' "$v" "$d" "$p" \
            "$(awk -v hq="$HOURS_PER_QUERY_SF1" -v dq="$DIR_QUERIES" -v n="$EXEC_PER_QUERY" -v s="$(sf_of "$d")" 'BEGIN{print hq*dq*n*s}')"
    done
fi
if [ ${#SKIPPED[@]} -gt 0 ]; then
    echo
    echo "  skipped:"
    printf '    %s\n' "${SKIPPED[@]}"
fi
echo
printf '  ESTIMATED TOTAL: %.1f h  (finishes ~%s)\n' "$TOTAL_HOURS" \
       "$(date -d "+${TOTAL_HOURS%.*} hours" '+%a %H:%M' 2>/dev/null || echo '?')"
echo "====================================================================="
echo

[ "$DRYRUN" = "1" ] && { echo "DRYRUN=1, stopping here."; exit 0; }
[ ${#COMBOS[@]} -eq 0 ] && exit 0

# ------------------------------------------------------------------ run
FINISHED=0
FAILED=0
START_ALL=$(date +%s)

on_interrupt() {
    echo
    log "INTERRUPTED after $FINISHED/${#COMBOS[@]} combinations ($(fmt_hms $(($(date +%s) - START_ALL))) elapsed)"
    log "Re-run the same command to resume; completed combinations are skipped."
    exit 130
}
trap on_interrupt INT TERM

log "matrix start: ${#COMBOS[@]} combinations, estimated ${TOTAL_HOURS}h"

for c in "${COMBOS[@]}"; do
    IFS=: read -r ver db port <<< "$c"
    combo_log="$MATRIX_DIR/pg${ver}_${db}.log"
    log "[$((FINISHED + FAILED + 1))/${#COMBOS[@]}] START PG$ver $db (port $port) -> $combo_log"
    t0=$(date +%s)

    make run PGVER="$ver" DB_NAME="$db" RUNS="$RUNS" WARMUP="$WARMUP" \
             BATCHNUM="$BATCHNUM" \
             DIR="$DIR" WORKERS="$WORKERS" STATEMENT_TIMEOUT="$STATEMENT_TIMEOUT" \
             > "$combo_log" 2>&1
    rc=$?
    dt=$(($(date +%s) - t0))

    # Query-level failures do not fail the combination; they are counted in the
    # CSV's "failures" column and echoed here so the morning summary shows them.
    # grep -c prints "0" AND exits 1 when nothing matches, so swallow the exit
    # status rather than appending a second "0".
    qfail=$(grep -c 'FAILED' "$combo_log" 2>/dev/null || true)
    qfail=${qfail:-0}

    if [ $rc -eq 0 ]; then
        FINISHED=$((FINISHED + 1))
        printf '%s\t%s\t%s\t%s\t%s\n' "$ver" "$db" "$(date -Iseconds)" "$dt" "$qfail" >> "$MANIFEST"
        log "    OK   PG$ver $db in $(fmt_hms $dt) ($qfail query failures)"
    else
        FAILED=$((FAILED + 1))
        log "    FAIL PG$ver $db after $(fmt_hms $dt) (make exit $rc) - see $combo_log"
        tail -3 "$combo_log" | sed 's/^/         /' | tee -a "$MASTER_LOG"
    fi
done

# ------------------------------------------------------------------ summary
echo | tee -a "$MASTER_LOG"
log "MATRIX DONE in $(fmt_hms $(($(date +%s) - START_ALL))): $FINISHED ok, $FAILED failed"
echo
echo "=========================== RESULT FILES ==========================="
ls -la query_timing_*.csv query_samples_*.csv query_slope_*.csv query_catalog_*.csv 2>/dev/null | awk '{printf "  %-34s %10s bytes\n", $NF, $5}'
echo
echo "  batch rows per version x database (query_timing):"
for f in query_timing_*.csv; do
    [ -e "$f" ] || continue
    awk -F, -v f="$f" 'NR>1 {n[$3]++} END {for (v in n) printf "    %-28s PG%-8s %6d batch rows\n", f, v, n[v]}' "$f"
done
echo "==================================================================="
