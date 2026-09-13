#!/usr/bin/env bash
#
# run_equivalent.sh - orchestrates the full night: plan-consistency snapshots,
# then a cold-cache sweep, then the warm matrix. Uses ONLY your existing tools
# (plan_snapshots.sh, `make cold`, `make matrix`) - nothing new is measured
# here, this just sequences them and keeps a log.
#
# Deliberately does NOT use `set -e`: one failing combination should not stop
# the rest of the night, same reasoning as run_matrix.sh's own comments.
#
# USAGE:
#   nohup bash overnight_run.sh > overnight.out 2>&1 &
#   disown
#   tail -f overnight_run.log     # check progress any time
#
# ENV VARS (all optional):
#   PGVERS       PostgreSQL versions                     (default: 16 18)
#   DBS          databases / TPC-H sizes                 (default: tpch tpch2 tpch5)
#   DIR          query directory, forwarded to all three  (default: queries/planner_tests)
#   REPEATS      plan snapshot repeats                    (default: 10)
#   COLD_RUNS    RUNS for `make cold`, per combination     (default: 15)
#   MATRIX_RUNS  RUNS for `make matrix`                    (default: 15)
#   WARMUP       WARMUP for `make matrix`                  (default: 2)
#   BATCHNUM     BATCHNUM for `make matrix`                (default: 1)
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

PGVERS="${PGVERS:-16 18}"
DBS="${DBS:-tpch tpch2 tpch5}"
DIR="${DIR:-queries/EquivalentQueries"
REPEATS="${REPEATS:-10}"
COLD_RUNS="${COLD_RUNS:-15}"
MATRIX_RUNS="${MATRIX_RUNS:-15}"
WARMUP="${WARMUP:-2}"
BATCHNUM="${BATCHNUM:-1}"

LOG="overnight_run.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }

log "===== EQUIVALENT RUN START ====="
log "PGVERS=$PGVERS DBS=$DBS DIR=$DIR"
log "REPEATS=$REPEATS COLD_RUNS=$COLD_RUNS MATRIX_RUNS=$MATRIX_RUNS WARMUP=$WARMUP BATCHNUM=$BATCHNUM"

# ---------------------------------------------------------- 1) plan snapshots
log "--- stage 1/3: plan consistency snapshots ---"
PGVERS="$PGVERS" DBS="$DBS" DIR="$DIR" REPEATS="$REPEATS" \
    bash plan_snapshots.sh >> "$LOG" 2>&1
rc=$?
[ $rc -eq 0 ] && log "stage 1 OK" || log "stage 1 FAILED (exit $rc) - see $LOG above, continuing anyway"

# ---------------------------------------------------------- 2) cold sweep
log "--- stage 2/3: cold-cache timing + RAPL, per version x size ---"
COLD_OK=0
COLD_FAIL=0
for ver in $PGVERS; do
    for db in $DBS; do
        log "  make cold PGVER=$ver DB_NAME=$db RUNS=$COLD_RUNS DIR=$DIR"
        make cold PGVER="$ver" DB_NAME="$db" RUNS="$COLD_RUNS" DIR="$DIR" >> "$LOG" 2>&1
        rc=$?
        if [ $rc -eq 0 ]; then
            COLD_OK=$((COLD_OK + 1))
            log "    OK   PG$ver/$db"
        else
            COLD_FAIL=$((COLD_FAIL + 1))
            log "    FAIL PG$ver/$db (exit $rc) - see $LOG above, continuing to next combination"
        fi
    done
done
log "stage 2 done: $COLD_OK ok, $COLD_FAIL failed"

# ---------------------------------------------------------- 3) warm matrix
log "--- stage 3/3: warm matrix sweep (resumable) ---"
make matrix PGVERS="$PGVERS" DBS="$DBS" DIR="$DIR" RUNS="$MATRIX_RUNS" \
    WARMUP="$WARMUP" BATCHNUM="$BATCHNUM" >> "$LOG" 2>&1
rc=$?
[ $rc -eq 0 ] && log "stage 3 OK" || log "stage 3 FAILED (exit $rc) - see $LOG above"

log "===== EQUIVALENT RUN DONE ====="S