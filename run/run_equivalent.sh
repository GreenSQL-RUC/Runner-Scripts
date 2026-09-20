#!/usr/bin/env bash
#
# run_equivalent.sh - one unattended night over the EQUIVALENT query set
# (queries/equivalent/tpch: the same result written ten different ways):
#   1. plan consistency snapshots   (test/plan_snapshots.sh, `make plans APPEND=1`)
#   2. cold-cache runs              (`make cold`, per version x database)
#   3. the warm step-up matrix      (`make matrix`, resumable)
# Nothing new is measured here; this only sequences the existing tools and
# keeps a log. No `set -e`: one failing stage/combination does not stop the rest.
#
#   nohup sudo bash run/run_equivalent.sh > overnight.out 2>&1 & disown
#   tail -f overnight_run.log
#
# ENV (all optional): PGVERS (16 18)  DBS (tpch tpch2 tpch5)  DIR
# (queries/equivalent/tpch)  REPEATS (plan snapshot repeats, 10)  COLD_RUNS
# (`make cold` RUNS, 15)  WARM_REPEATS (`make matrix` REPEATS, 3)  WARMUP (2)
# BATCH_SIZES ("1 16")  RUNS (measured batches per size, 1)
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"          # repo root
cd "$ROOT" || exit 1

PGVERS="${PGVERS:-16 18}"
DBS="${DBS:-tpch tpch2 tpch5}"
DIR="${DIR:-queries/equivalent/tpch}"
REPEATS="${REPEATS:-10}"
COLD_RUNS="${COLD_RUNS:-15}"
WARM_REPEATS="${WARM_REPEATS:-3}"
WARMUP="${WARMUP:-2}"
BATCH_SIZES="${BATCH_SIZES:-1 16}"
RUNS="${RUNS:-1}"

LOG="overnight_run.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }

log "===== EQUIVALENT RUN START ====="
log "PGVERS=$PGVERS DBS=$DBS DIR=$DIR"
log "REPEATS=$REPEATS COLD_RUNS=$COLD_RUNS WARM_REPEATS=$WARM_REPEATS WARMUP=$WARMUP BATCH_SIZES='$BATCH_SIZES' RUNS=$RUNS"

# ---------------------------------------------------------- 1) plan snapshots
log "--- stage 1/3: plan consistency snapshots ---"
PGVERS="$PGVERS" DBS="$DBS" DIR="$DIR" REPEATS="$REPEATS" bash test/plan_snapshots.sh >> "$LOG" 2>&1
rc=$?
[ $rc -eq 0 ] && log "stage 1 OK" || log "stage 1 FAILED (exit $rc) - see $LOG above, continuing anyway"

# ---------------------------------------------------------- 2) cold runs
log "--- stage 2/3: cold-cache timing + RAPL, per version x database ---"
COLD_OK=0; COLD_FAIL=0
for ver in $PGVERS; do
    for db in $DBS; do
        log "  make cold PGVER=$ver DB_NAME=$db RUNS=$COLD_RUNS DIR=$DIR"
        make cold PGVER="$ver" DB_NAME="$db" RUNS="$COLD_RUNS" DIR="$DIR" >> "$LOG" 2>&1
        rc=$?
        if [ $rc -eq 0 ]; then COLD_OK=$((COLD_OK + 1)); log "    OK   PG$ver/$db"
        else COLD_FAIL=$((COLD_FAIL + 1)); log "    FAIL PG$ver/$db (exit $rc) - see $LOG above, continuing"; fi
    done
done
log "stage 2 done: $COLD_OK ok, $COLD_FAIL failed"

# ---------------------------------------------------------- 3) warm matrix
log "--- stage 3/3: warm step-up matrix (resumable) ---"
make matrix PGVERS="$PGVERS" DBS="$DBS" DIR="$DIR" REPEATS="$WARM_REPEATS" \
    WARMUP="$WARMUP" BATCH_SIZES="$BATCH_SIZES" RUNS="$RUNS" >> "$LOG" 2>&1
rc=$?
[ $rc -eq 0 ] && log "stage 3 OK" || log "stage 3 FAILED (exit $rc) - see $LOG above"

log "===== EQUIVALENT RUN DONE ====="
