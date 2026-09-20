#!/usr/bin/env bash
#
# plan_snapshots.sh - plan CONSISTENCY test (`make plan-snapshots`).
#
# Runs `make plans APPEND=1` REPEATS times for every PGVERS x DBS combination,
# so each query's plan file under $PLANS_DIR/snapshots/pg<ver>/<db>/ accumulates
# one dated snapshot per repeat, and plan_builder compares each new snapshot's
# SHAPE (node tree, scan/join methods, relations - not the cost/row/timing
# numbers) with the previous one. The drift summary at the end lists every
# query whose shape changed at least once.
#
# plan_builder runs EXPLAIN ANALYZE, so the plans are the executed ones; cache
# state cannot change a plan, but GEQO (many-join queries) and autoanalyze stats
# drift can. SLEEP_SECS spreads the repeats out to give the latter a chance.
#
#   PGVERS="16 18" DBS="tpch tpch_idx" REPEATS=10 bash test/plan_snapshots.sh
#   DRYRUN=1 bash test/plan_snapshots.sh
#
# ENV: PGVERS (default 16 18)  DBS (default tpch)  DIR (default
# queries/equivalent/tpch)  REPEATS (default 5)  SLEEP_SECS (default 0)
# PLANS_DIR (default plans)  DRYRUN
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"          # repo root (this script lives in test/)
cd "$ROOT" || exit 1

PGVERS="${PGVERS:-16 18}"
DBS="${DBS:-tpch}"
DIR="${DIR:-queries/equivalent/tpch}"
REPEATS="${REPEATS:-5}"
SLEEP_SECS="${SLEEP_SECS:-0}"
PLANS_DIR="${PLANS_DIR:-plans}"
OUT_ROOT="$PLANS_DIR/snapshots"
DRYRUN="${DRYRUN:-0}"; [ "$DRYRUN" = "" ] && DRYRUN=0

LOG="$OUT_ROOT/snapshots.log"
mkdir -p "$OUT_ROOT"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }

echo
echo "========================= PLAN SNAPSHOT PLAN ========================="
printf '  versions   %s\n' "$PGVERS"
printf '  databases  %s\n' "$DBS"
printf '  queries    %s\n' "$DIR"
printf '  repeats    %s%s\n' "$REPEATS" "$([ "$SLEEP_SECS" != "0" ] && echo ", ${SLEEP_SECS}s apart" || echo ", back to back")"
printf '  output     %s/pg<version>/<db>/<query>.txt  (one snapshot section per repeat)\n' "$OUT_ROOT"
echo "=========================================================================="
echo

[ "$DRYRUN" = "1" ] && { echo "DRYRUN=1, stopping here."; exit 0; }

declare -A DRIFT      # "pg<ver>/<db>/<query>" -> times the shape changed
for r in $(seq 1 "$REPEATS"); do
    log "=== repeat $r/$REPEATS ==="
    for ver in $PGVERS; do
        for db in $DBS; do
            plans_dir="$OUT_ROOT/pg${ver}"
            out="$OUT_ROOT/pg${ver}_${db}_repeat${r}.log"
            log "  make plans APPEND=1 PGVER=$ver DB_NAME=$db DIR=$DIR PLANS_DIR=$plans_dir"
            make -C "$ROOT" plans APPEND=1 PGVER="$ver" DB_NAME="$db" DIR="$DIR" PLANS_DIR="$plans_dir" > "$out" 2>&1
            rc=$?
            [ $rc -ne 0 ] && log "  !! make plans failed (exit $rc) for PG$ver/$db repeat $r - see $out"
            while IFS= read -r q; do
                key="pg$ver/$db/$q"; DRIFT["$key"]=$(( ${DRIFT["$key"]:-0} + 1 ))
                log "  DRIFT  PG$ver/$db  $q  (repeat $r)"
            done < <(sed -n 's/^  \[[0-9]*\/[0-9]*\] \(.*\) -> snapshot [0-9]*  SHAPE CHANGED.*/\1/p' "$out")
        done
    done
    if [ "$r" -lt "$REPEATS" ] && [ "$SLEEP_SECS" != "0" ]; then
        log "  sleeping ${SLEEP_SECS}s before next repeat"
        sleep "$SLEEP_SECS"
    fi
done

echo
echo "=========================== DRIFT SUMMARY ==========================="
if [ ${#DRIFT[@]} -eq 0 ]; then
    echo "  no plan shape changed across $REPEATS repeats - the planner was consistent"
else
    for k in "${!DRIFT[@]}"; do printf '  DRIFT  %-45s shape changed %d time(s)\n' "$k" "${DRIFT[$k]}"; done | sort
fi
echo
echo "  snapshots: $OUT_ROOT/pg<version>/<db>/<query>.txt   log: $LOG"
echo "========================================================================"
