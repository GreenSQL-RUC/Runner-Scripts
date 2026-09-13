#!/usr/bin/env bash
#
# plan_snapshots.sh - call `make plans`
# REPEATS times, each into its own directory, then diff the snapshots against
# each other to see whether any query's saved plan changed between runs.
#
# This adds NOTHING to cold_runner.c / query_runner.c / the Makefile - it's a
# pure wrapper around `make plans`, which already exists and already writes a
# full plan per query with no changes needed on your end.
#
# NOTE: `make plans` runs plan_builder, which per the Makefile's own comment
# does "no measuring" - i.e. a plain EXPLAIN, not EXPLAIN ANALYZE. That means
# it never executes the query, so cache state (cold/warm) cannot affect its
# output. Repeating it several times in order to catches real
# planner stochasticity (GEQO, if the queries have enough joins to trigger
# it) or catalog stats drifting between runs (autoanalyze) - just not for a
# cache-warmth reason.
#
# USAGE:
#   PGVERS="16 18" DBS="tpch tpch2" REPEATS=10 bash plan_snapshots.sh
#   DRYRUN=1 bash plan_snapshots.sh          # print the plan, run nothing
#
# ENV VARS:
#   PGVERS      PostgreSQL versions to check              (default: 16 18)
#   DBS         databases to check                        (default: tpch)
#   DIR         forwarded to `make plans DIR=...`          (default: Makefile's own default)
#   REPEATS     how many separate plan snapshots to take   (default: 5)
#   SLEEP_SECS  seconds to wait between repeats            (default: 0)
#               (nonzero spreads repeats over time, useful if you want a
#               chance to catch autoanalyze-driven drift rather than firing
#               all repeats back to back)
#   OUT_ROOT    where snapshots + diff log go              (default: plan_snapshots)
#   DRYRUN      1 = print the plan, run nothing            (default: 0)
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

PGVERS="${PGVERS:-16 18}"
DBS="${DBS:-tpch}"
DIR="${DIR:-queries/EquivalentQueries}"
REPEATS="${REPEATS:-5}"
SLEEP_SECS="${SLEEP_SECS:-0}"
OUT_ROOT="${OUT_ROOT:-plan_snapshots}"
DRYRUN="${DRYRUN:-0}"

LOG="$OUT_ROOT/snapshots.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }

if [ ! -f "$HERE/Makefile" ]; then
    echo "!! no Makefile found in $HERE - run this from Runner-Scripts" >&2
    exit 1
fi

echo
echo "========================= PLAN SNAPSHOT PLAN ========================="
printf '  versions   %s\n' "$PGVERS"
printf '  databases  %s\n' "$DBS"
printf '  repeats    %s%s\n' "$REPEATS" "$([ "$SLEEP_SECS" != "0" ] && echo ", ${SLEEP_SECS}s apart" || echo ", back to back")"
printf '  dir        %s\n' "${DIR:-(Makefile default)}"
printf '  output     %s/run<N>/pg<version>/<db>/\n' "$OUT_ROOT"
echo "  NOTE: plan_builder does a non-executing EXPLAIN, so cold/warm cache"
echo "        state cannot change its output - this only catches genuine"
echo "        planner stochasticity (e.g. GEQO) or stats drift over time."
echo "=========================================================================="
echo

[ "$DRYRUN" = "1" ] && { echo "DRYRUN=1, stopping here."; exit 0; }

mkdir -p "$OUT_ROOT"

for r in $(seq 1 "$REPEATS"); do
    log "=== repeat $r/$REPEATS ==="
    for ver in $PGVERS; do
        for db in $DBS; do
            plans_dir="$OUT_ROOT/run${r}/pg${ver}"
            mkdir -p "$plans_dir"
            log "  make plans PGVER=$ver DB_NAME=$db PLANS_DIR=$plans_dir"
            if [ -n "$DIR" ]; then
                make plans PGVER="$ver" DB_NAME="$db" PLANS_DIR="$plans_dir" DIR="$DIR" \
                    >> "$LOG" 2>&1
            else
                make plans PGVER="$ver" DB_NAME="$db" PLANS_DIR="$plans_dir" \
                    >> "$LOG" 2>&1
            fi
            rc=$?
            [ $rc -ne 0 ] && log "  !! make plans failed (exit $rc) for PG$ver/$db repeat $r - see $LOG"
        done
    done
    if [ "$r" -lt "$REPEATS" ] && [ "$SLEEP_SECS" != "0" ]; then
        log "  sleeping ${SLEEP_SECS}s before next repeat"
        sleep "$SLEEP_SECS"
    fi
done

echo
echo "=========================== DRIFT SUMMARY ==========================="
DRIFT_FOUND=0
for ver in $PGVERS; do
    for db in $DBS; do
        base="$OUT_ROOT/run1/pg${ver}/${db}"
        [ -d "$base" ] || { echo "  !! no plans dir for PG$ver/$db (run 1) - skipping"; continue; }
        for r in $(seq 2 "$REPEATS"); do
            cur="$OUT_ROOT/run${r}/pg${ver}/${db}"
            [ -d "$cur" ] || continue
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                echo "  DRIFT  PG$ver/$db  run1 vs run$r:  $line"
                DRIFT_FOUND=1
            done < <(diff -rq "$base" "$cur" 2>/dev/null)
        done
    done
done
if [ "$DRIFT_FOUND" = "0" ]; then
    echo "  no differences found - every repeat produced identical plan files"
fi
echo
echo "  raw snapshots: $OUT_ROOT/run<N>/pg<version>/<db>/"
echo "========================================================================"