#!/usr/bin/env bash
#
# planner_consistency.sh - run a set of queries many times under COLD and WARM
# cache states, to check whether the planner picks the same plan every time,
# and how much energy (RAPL) each run costs.
#
# This is deliberately standalone (not built on run_matrix.sh's sweep/manifest
# machinery) - one version, one database, one query directory per invocation.

#   
#
# WHAT GETS CAPTURED, PER RUN:
#   - EXPLAIN (plan only, not executed)      -> $OUT_DIR/plans/
#   - EXPLAIN (ANALYZE, BUFFERS) (executed)  -> $OUT_DIR/analyze/
#   - a summary CSV row with: timing (parsed from the plan's own "Execution
#     Time" line), RAPL energy delta, and two plan hashes (raw + "shape",
#     which strips cost/row/width estimates so it only changes when the
#     actual plan structure changes)
#
# USAGE:
#   sudo COLD_SCRIPT=./my_cache_drop.sh PGVER=18 DB=tpch bash planner_consistency.sh
#   sudo PGVER=16 DB=tpch2 STATES=warm RUNS=20 bash planner_consistency.sh
#   sudo DRYRUN=1 bash planner_consistency.sh          # show the plan, run nothing
#
# REQUIRED:
#   COLD_SCRIPT   Path to your existing script that drops the OS page cache
#                 AND restarts the target cluster. Required unless STATES
#                 excludes "cold". This script does NOT reimplement that
#                 logic - it just calls yours at the right moments.
#                 !! Check the call site marked "ADJUST ME" below - it invokes
#                 COLD_SCRIPT with the port as its only argument. Change that
#                 if your script expects different arguments.
#
# ENV VARS (all optional except COLD_SCRIPT when cold is in STATES):
#   PGVER               PostgreSQL major version to target      (default 18)
#   DB                  database name                           (default tpch)
#   DIR                 directory of .sql query files            (default queries)
#   STATES              "cold", "warm", or "cold warm"           (default "cold warm")
#   RUNS                passes through the full query set,       (default 10)
#                       per state - this is what lets you check
#                       consistency across repeated runs
#   WARMUP              warm-up executions per query before the  (default 2)
#                       first *measured* warm run (ignored for cold)
#   BATCHNUM            concurrent copies of each query run       (default 1)
#                       together per pass (same idea as run_matrix.sh's
#                       BATCHNUM: 1 = one copy at a time; >1 launches that
#                       many copies of the SAME query concurrently and the
#                       recorded timing becomes the wall-clock time for the
#                       whole concurrent batch, not a single query's own
#                       "Execution Time"). Energy is bracketed around the
#                       whole batch either way.
#   COLD_EACH_QUERY     1 = clear cache before every query        (default 1)
#                       0 = clear once per batch instead
#   STATEMENT_TIMEOUT   seconds, applied via SET statement_timeout (default 900)
#   OUT_DIR             where plans/analyze/CSV get written       (default planner_logs)
#   RAPL_GLOB           sysfs glob for energy counters             (default /sys/class/powercap/intel-rapl:*/energy_uj)
#   DRYRUN              1 = print the plan, run nothing            (default 0)
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

PGVER="${PGVER:-18}"
DB="${DB:-tpch}"
DIR="${DIR:-queries}"
STATES="${STATES:-cold warm}"
RUNS="${RUNS:-10}"
WARMUP="${WARMUP:-2}"
BATCHNUM="${BATCHNUM:-1}"
COLD_EACH_QUERY="${COLD_EACH_QUERY:-1}"
STATEMENT_TIMEOUT="${STATEMENT_TIMEOUT:-900}"
OUT_DIR="${OUT_DIR:-planner_logs}"
RAPL_GLOB="${RAPL_GLOB:-/sys/class/powercap/intel-rapl:*/energy_uj}"
DRYRUN="${DRYRUN:-0}"
COLD_SCRIPT="${COLD_SCRIPT:-}"

PLANS_DIR="$OUT_DIR/plans"
ANALYZE_DIR="$OUT_DIR/analyze"
CSV="$OUT_DIR/consistency_pg${PGVER}_${DB}.csv"
LOG="$OUT_DIR/run.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }

port_of() { pg_lsclusters -h 2>/dev/null | awk -v v="$1" '$1 == v && $2 == "main" { print $3 }'; }

# ------------------------------------------------------------------ energy
# Sums energy_uj across every matched RAPL zone. NOTE: each zone's counter
# wraps independently at that zone's max_energy_range_uj, on the order of
# tens of seconds to a few minutes depending on hardware. For a single query
# this is very unlikely to wrap, but a negative delta below is FLAGGED, not
# silently treated as a real (impossible) negative energy reading.
read_energy_uj() {
    local total=0 f val
    for f in $RAPL_GLOB; do
        [ -r "$f" ] || continue
        val="$(cat "$f" 2>/dev/null)" || continue
        total=$((total + val))
    done
    echo "$total"
}

RAPL_OK=1
if [ -z "$(read_energy_uj)" ] || [ "$(read_energy_uj)" = "0" ]; then
    echo "!! WARNING: no readable RAPL zones matched '$RAPL_GLOB'." >&2
    echo "!! Energy columns will be recorded as 'na'. You likely need to run" >&2
    echo "!! as root, or check the glob matches your hardware's zones." >&2
    RAPL_OK=0
fi

# ------------------------------------------------------------------ plan hashing
# "shape" hash strips cost/row/width estimates and actual timing/loop counts
# so it only changes when the plan's actual STRUCTURE changes (different join
# order, different scan/join method, etc), not just when stats drift slightly.
normalize_plan() {
    sed -E \
        -e 's/\(cost=[0-9.]+\.\.[0-9.]+ rows=[0-9]+ width=[0-9]+\)//g' \
        -e 's/\(actual time=[0-9.]+\.\.[0-9.]+ rows=[0-9]+ loops=[0-9]+\)//g' \
        -e 's/Planning Time: .*//' \
        -e 's/Execution Time: .*//' \
        -e 's/Buffers: .*//'
}

hash_of() { sha256sum | awk '{print $1}'; }

# ------------------------------------------------------------------ db calls
run_psql() {
    local port="$1" sql="$2"
    sudo -u postgres psql -p "$port" -d "$DB" -v ON_ERROR_STOP=0 -qAt \
        -c "SET statement_timeout = ${STATEMENT_TIMEOUT}s; $sql" 2>&1
}

do_cold_clear() {
    local port="$1"
    if [ -z "$COLD_SCRIPT" ]; then
        echo "!! COLD_SCRIPT is not set but a cold run was requested. Aborting." >&2
        exit 1
    fi
    # ADJUST ME: change the arguments here if your script expects something
    # other than the cluster's port (e.g. the version number instead).
    bash "$COLD_SCRIPT" "$port" >> "$LOG" 2>&1
}

# ------------------------------------------------------------------ setup
port="$(port_of "$PGVER")"
if [ -z "$port" ]; then
    echo "!! no 'main' cluster found for PostgreSQL $PGVER (check pg_lsclusters)" >&2
    exit 1
fi

mapfile -t QUERY_FILES < <(find "$DIR" -maxdepth 1 -name '*.sql' | sort)
if [ "${#QUERY_FILES[@]}" -eq 0 ]; then
    echo "!! no .sql files found under $DIR" >&2
    exit 1
fi

echo
echo "======================= PLANNER CONSISTENCY PLAN ======================="
printf '  target       PG%s on port %s, database %s\n' "$PGVER" "$port" "$DB"
printf '  queries      %s  (%s files)\n' "$DIR" "${#QUERY_FILES[@]}"
printf '  states       %s\n' "$STATES"
printf '  passes       %s  (per state)\n' "$RUNS"
printf '  warmup       %s executions before the first measured warm run\n' "$WARMUP"
printf '  batchnum     %s %s\n' "$BATCHNUM" "$([ "$BATCHNUM" -gt 1 ] && echo '(concurrent copies per pass, wall-clock timed)' || echo '(one copy at a time)')"
printf '  cold clear   %s\n' "$([ "$COLD_EACH_QUERY" = "1" ] && echo 'before every query' || echo 'once per pass')"
printf '  RAPL         %s\n' "$([ "$RAPL_OK" = "1" ] && echo "OK ($RAPL_GLOB)" || echo 'NOT READABLE - energy will be recorded as na')"
printf '  output       %s\n' "$OUT_DIR"
echo "=========================================================================="
echo

[ "$DRYRUN" = "1" ] && { echo "DRYRUN=1, stopping here."; exit 0; }

mkdir -p "$PLANS_DIR" "$ANALYZE_DIR"
if [ ! -f "$CSV" ]; then
    echo "timestamp,state,pgver,db,query,pass,batchnum,execution_time_ms,energy_uj,plan_hash,plan_shape_hash" > "$CSV"
fi

on_interrupt() {
    echo
    log "INTERRUPTED - partial results are already saved in $OUT_DIR"
    exit 130
}
trap on_interrupt INT TERM

# ------------------------------------------------------------------ run
for state in $STATES; do
    log "=== state: $state ==="

    for pass in $(seq 1 "$RUNS"); do
        # Once-per-batch cold clear, if that mode was chosen.
        if [ "$state" = "cold" ] && [ "$COLD_EACH_QUERY" != "1" ]; then
            log "  [pass $pass] clearing cache+restarting cluster (once for this pass)"
            do_cold_clear "$port"
        fi

        for qfile in "${QUERY_FILES[@]}"; do
            qname="$(basename "$qfile" .sql)"

            if [ "$state" = "cold" ] && [ "$COLD_EACH_QUERY" = "1" ]; then
                do_cold_clear "$port"
            elif [ "$state" = "warm" ] && [ "$pass" = "1" ] && [ "$WARMUP" -gt 0 ]; then
                for w in $(seq 1 "$WARMUP"); do
                    run_psql "$port" "EXPLAIN (ANALYZE, BUFFERS) $(cat "$qfile")" > /dev/null
                done
            fi

            plan_raw="$(run_psql "$port" "EXPLAIN $(cat "$qfile")")"
            echo "$plan_raw" > "$PLANS_DIR/${state}_${qname}_pass${pass}.txt"
            plan_hash="$(echo "$plan_raw" | hash_of)"
            shape_hash="$(echo "$plan_raw" | normalize_plan | hash_of)"

            e0="$(read_energy_uj)"
            if [ "$BATCHNUM" -gt 1 ]; then
                # Launch BATCHNUM copies of the SAME query concurrently.
                # Timing here is the wall-clock time for the whole batch to
                # finish, not any single copy's own "Execution Time" - that's
                # the meaningful number when the point is concurrent load.
                pids=()
                copy_files=()
                t0_ns=$(date +%s%N)
                for b in $(seq 1 "$BATCHNUM"); do
                    cf="$ANALYZE_DIR/${state}_${qname}_pass${pass}_copy${b}.txt"
                    ( run_psql "$port" "EXPLAIN (ANALYZE, BUFFERS) $(cat "$qfile")" > "$cf" ) &
                    pids+=("$!")
                    copy_files+=("$cf")
                done
                for pid in "${pids[@]}"; do wait "$pid"; done
                t1_ns=$(date +%s%N)
                exec_ms=$(( (t1_ns - t0_ns) / 1000000 ))
                # Use the first copy's output as the representative plan/analyze
                # record - all copies ran the identical query concurrently.
                analyze_out="$(cat "${copy_files[0]}")"
            else
                analyze_out="$(run_psql "$port" "EXPLAIN (ANALYZE, BUFFERS) $(cat "$qfile")")"
                echo "$analyze_out" > "$ANALYZE_DIR/${state}_${qname}_pass${pass}.txt"
                exec_ms="$(echo "$analyze_out" | grep -oP 'Execution Time: \K[0-9.]+' | head -1)"
                exec_ms="${exec_ms:-na}"
            fi
            e1="$(read_energy_uj)"

            if [ "$RAPL_OK" = "1" ]; then
                energy_delta=$((e1 - e0))
                if [ "$energy_delta" -lt 0 ]; then
                    log "  !! negative energy delta for $qname pass $pass ($state) - counter likely wrapped, flagging as na"
                    energy_delta="na"
                fi
            else
                energy_delta="na"
            fi

            printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
                "$(date -Iseconds)" "$state" "$PGVER" "$DB" "$qname" "$pass" "$BATCHNUM" \
                "$exec_ms" "$energy_delta" "$plan_hash" "$shape_hash" >> "$CSV"
        done
        log "  [pass $pass/$RUNS] done ($state)"
    done
done

# ------------------------------------------------------------------ summary
echo
echo "=========================== CONSISTENCY SUMMARY ==========================="
awk -F, 'NR>1 {key=$2"|"$5; shapes[key]=shapes[key]" "$11} END {
    for (k in shapes) {
        n=split(shapes[k], arr, " ");
        delete seen;
        distinct=0;
        for (i=1;i<=n;i++) if (!seen[arr[i]]++) distinct++;
        split(k, parts, "|");
        if (distinct > 1) printf "  DRIFT   state=%-5s query=%-15s %d distinct plan shapes across %d runs\n", parts[1], parts[2], distinct, n;
    }
}' "$CSV"
echo
echo "  (no DRIFT lines above = every run picked the same plan shape)"
echo "  full data: $CSV"
echo "=============================================================================="