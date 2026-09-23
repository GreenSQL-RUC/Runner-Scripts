#!/usr/bin/env bash
#
# run_slope_sample.sh - run both tiers of the slope-accuracy test, back to back.
#
# Stage the sample first with test/build_slope_sample.py. Then, detached:
#
#   setsid nohup bash run/detach.sh logs/slope_sample/console.log \
#       bash test/run_slope_sample.sh > /dev/null 2>&1 < /dev/null &
#
# 1. REFERENCE: 4 queries per energy band x 10 repeats, full step-up 1..16.
# 2. BREADTH:   ~220 queries x 3 repeats, step-up 1..16 but the 16-copy batch
#               is dropped when the warm single copy takes over 6 s.
# Both: warm step-up with a cold start per entry, 2 warm-ups, 60 s statement
# timeout, thermal gate 55-60 C, clock pinned at 2.5 GHz (the setting the
# SQLStorm energy bands were measured at). The reference tier runs first so
# the part that defines the true values is complete even if time runs short.
#
# Results: logs/slope_sample/warm_stepup/{reference,breadth}_<stamp>/
#
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

for f in logs/slope_sample/order_reference.txt logs/slope_sample/order_breadth.txt; do
    [ -f "$f" ] || { echo "missing $f - run test/build_slope_sample.py first" >&2; exit 1; }
done

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
COMMON=(
    DB_NAME=tpch_idx
    "BATCH_SIZES=1 2 4 8 16"
    WARMUP=2 RUNS=1
    STATEMENT_TIMEOUT=60
    THERMAL_EQUALISE=1 T_LO=55 T_HI=60 PREHEAT_MAX_S=60 COOLDOWN_MAX_S=120
    FIX_CLOCK=1 CLOCK_MAX_KHZ=2500000
    LOGS_DIR=logs/slope_sample
)

echo "== reference tier $(date -u +%H:%M:%SZ)"
make warm-stepup "${COMMON[@]}" \
    DIR=queries/tpch/sqlstorm_slope/reference \
    ORDER_FILE=logs/slope_sample/order_reference.txt \
    RUNID="reference_$STAMP"
rc_ref=$?

echo "== breadth tier $(date -u +%H:%M:%SZ)"
make warm-stepup "${COMMON[@]}" \
    DIR=queries/tpch/sqlstorm_slope/breadth \
    ORDER_FILE=logs/slope_sample/order_breadth.txt \
    BATCH_CAP_SLOW=8 SLOW_COPY_SEC=6 \
    RUNID="breadth_$STAMP"
rc_br=$?

echo "== done $(date -u +%H:%M:%SZ): reference exit $rc_ref, breadth exit $rc_br"
[ "$rc_ref" = 0 ] && [ "$rc_br" = 0 ]
