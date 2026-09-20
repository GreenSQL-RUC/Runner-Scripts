#!/usr/bin/env bash
#
# clock_sweep.sh - run the warm step-up benchmark once per pinned clock ceiling.
#
# Same protocol as a single `make warm-stepup` with FIX_CLOCK=1 (temperature
# gated start, then the measured batch step-up), repeated for each frequency in
# CLOCKS. Each pass gets its own run directory under logs/warm_stepup/, so the
# passes can be compared with test/thermal_check.py exactly like runs 1-3.
#
# The point of the sweep: at the base frequency (1.7 GHz here) the clock pin
# removed every throttle event, but it also removed most of the machine's speed.
# Raising the ceiling into the turbo range trades that back, and this finds the
# frequency at which thermal throttling and repeat noise return.
#
# UNATTENDED USE. It is meant to run overnight with nobody watching, so it:
#   - runs the passes strictly one after another, never in parallel;
#   - keeps going to the next pass if one fails, and reports both counts;
#   - restores the clock on exit, including Ctrl-C, SIGTERM and a failed pass;
#   - blocks suspend/idle/lid-close for its lifetime when systemd-inhibit is
#     available (a laptop that suspends mid-pass loses the run);
#   - writes one manifest listing every pass, its ceiling, run dir and status.
#
# Launch it detached so closing the terminal or the Claude session cannot kill
# it (the machine itself must stay powered on):
#
#   cd <repo> && setsid nohup bash run/clock_sweep.sh > /dev/null 2>&1 &
#
# ENV (defaults in brackets):
#   CLOCKS      ceilings in kHz, space separated  [2000000 2500000 3000000]
#   GAP_S       idle seconds between passes       [300]
#   SWEEP_DIR   where the manifest and pass logs go  [logs/clock_sweep/<stamp>]
#   plus every `make warm-stepup` knob: DB_NAME DIR REPEATS WARMUP BATCH_SIZES
#   RUNS STATEMENT_TIMEOUT THERMAL_EQUALISE T_LO T_HI PREHEAT_MAX_S
#   COOLDOWN_MAX_S SUDO_PASSWORD. The defaults below reproduce run 3.
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
cd "$ROOT" || exit 1

# Block the idle timer for the whole sweep. A normal user may only take the
# "idle" inhibitor; suspend and lid-close need root and are taken further down,
# once sudo has been primed. Re-exec once (the guard variable stops a loop).
if [ -z "${CLOCK_SWEEP_INHIBITED:-}" ] && command -v systemd-inhibit >/dev/null 2>&1; then
    export CLOCK_SWEEP_INHIBITED=1
    exec systemd-inhibit --what=idle --who="GreenSQL clock sweep" \
         --why="benchmark pass in progress" --mode=block bash "$0" "$@"
fi

CLOCKS="${CLOCKS:-2000000 2500000 3000000}"
GAP_S="${GAP_S:-300}"

# --- run 3's parameters, overridable ------------------------------------------
DB_NAME="${DB_NAME:-tpch_idx}"
DIR="${DIR:-queries/tpch/tpch-queries}"
REPEATS="${REPEATS:-3}"
WARMUP="${WARMUP:-2}"
BATCH_SIZES="${BATCH_SIZES:-1 2 4 8 16}"
RUNS="${RUNS:-1}"
STATEMENT_TIMEOUT="${STATEMENT_TIMEOUT:-900}"
THERMAL_EQUALISE="${THERMAL_EQUALISE:-1}"
T_LO="${T_LO:-55}"
T_HI="${T_HI:-60}"
PREHEAT_MAX_S="${PREHEAT_MAX_S:-60}"
COOLDOWN_MAX_S="${COOLDOWN_MAX_S:-120}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SWEEP_DIR="${SWEEP_DIR:-logs/clock_sweep/$STAMP}"
mkdir -p "$SWEEP_DIR" || { echo "cannot create $SWEEP_DIR" >&2; exit 1; }
MANIFEST="$SWEEP_DIR/manifest.txt"
LOG="$SWEEP_DIR/sweep.log"
# Reference timestamp: only clock_state files newer than this belong to us.
MARKER="$SWEEP_DIR/.started"
: > "$MARKER"

# Everything this script prints goes to the sweep log as well as stdout, so a
# detached run leaves a complete record.
exec > >(tee -a "$LOG") 2>&1

say(){ echo "[$(date -u +%H:%M:%SZ)] $*"; }

# --- safety: never start on top of a live benchmark ---------------------------
# Only RUNNING runners matter; long-stopped ones (state T) hold no connection.
live_runner=""
for pid in $(pgrep -x 'query_runner|cold_runner|write_runner' 2>/dev/null); do
    st="$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)"
    case "$st" in T|t|Z|"") continue ;; esac
    live_runner="$pid"; break
done
if [ -n "$live_runner" ]; then
    say "!! a runner is already live (PID $live_runner); refusing to start a sweep"
    exit 1
fi

# --- sudo, and block suspend / lid-close for the sweep's lifetime -------------
# Every pass needs root anyway (RAPL, drop_caches, pg_ctlcluster); prime it once
# here as well so the inhibitor below can be taken without a prompt.
printf '%s\n' "${SUDO_PASSWORD:-a}" | sudo -S -v 2>/dev/null
INHIBIT_PID=""
if command -v systemd-inhibit >/dev/null 2>&1; then
    # A root helper holds the inhibitor and exits as soon as this script does,
    # so suspend is blocked for exactly as long as the sweep runs.
    sudo -n systemd-inhibit --what=sleep:handle-lid-switch \
        --who="GreenSQL clock sweep" --why="benchmark pass in progress" --mode=block \
        bash -c "while kill -0 $$ 2>/dev/null; do sleep 30; done" >/dev/null 2>&1 &
    INHIBIT_PID=$!
fi

# --- restore the clock whatever happens ---------------------------------------
# run_warm_stepup.sh restores its own pin at the end of each pass; this is the
# backstop for a pass killed between apply and restore.
cleanup() {
    rc=$?
    # run_warm_stepup.sh deletes its clock_state once it has restored the pin,
    # so any state file this sweep created that still exists means a pass died
    # with the clock still pinned. Restore from it: those are the exact values
    # that were saved before the pin.
    local left
    left="$(find logs/warm_stepup -maxdepth 2 -name clock_state -newer "$MARKER" 2>/dev/null)"
    if [ -n "$left" ]; then
        printf '%s\n' "${SUDO_PASSWORD:-a}" | sudo -S -v 2>/dev/null
        for st in $left; do
            say "restoring clock from $st (a pass exited while pinned)"
            sudo -n bash "$HERE/clock_control.sh" restore "$st"
        done
    fi
    say "final clock state: $(bash "$HERE/clock_control.sh" status | tr '\n' ' ')"
    [ -n "${INHIBIT_PID:-}" ] && kill "$INHIBIT_PID" 2>/dev/null
    exit $rc
}
trap cleanup EXIT INT TERM

say "clock sweep: ceilings [$CLOCKS] kHz   DB=$DB_NAME  REPEATS=$REPEATS  BATCH_SIZES='$BATCH_SIZES'"
say "  thermal gate ${T_LO}-${T_HI} C, FIX_CLOCK=1, gap ${GAP_S}s between passes"
say "  sweep dir: $SWEEP_DIR"
hw_max="$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo '?')"
base="$(cat /sys/devices/system/cpu/cpu0/cpufreq/base_frequency 2>/dev/null || echo '?')"
say "  cpu: base ${base} kHz, max turbo ${hw_max} kHz"
if [ -n "$INHIBIT_PID" ]; then
    say "  suspend/lid-close inhibited for the sweep (idle inhibited too)"
else
    say "  WARNING: systemd-inhibit unavailable; a suspend would kill the sweep"
fi

{
    echo "# clock sweep $STAMP"
    echo "# cpu base_khz=$base max_turbo_khz=$hw_max"
    echo "# db=$DB_NAME dir=$DIR repeats=$REPEATS warmup=$WARMUP batch_sizes='$BATCH_SIZES'"
    echo "# thermal_equalise=$THERMAL_EQUALISE t_lo=$T_LO t_hi=$T_HI fix_clock=1"
    echo "# pass  clock_khz  started_utc  duration  status  run_dir"
} > "$MANIFEST"

pass=0; ok=0; failed=0
for khz in $CLOCKS; do
    pass=$((pass + 1))
    if [ -n "$hw_max" ] && [ "$hw_max" != "?" ] && [ "$khz" -gt "$hw_max" ]; then
        say "pass $pass: ${khz} kHz is above the hardware maximum ${hw_max}; skipping"
        printf '%-6s %-10s %-20s %-9s %-8s %s\n' "$pass" "$khz" "-" "-" "skipped" "-" >> "$MANIFEST"
        continue
    fi

    pass_log="$SWEEP_DIR/pass${pass}_${khz}.log"
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    t0=$(date +%s)
    say "pass $pass/$(echo $CLOCKS | wc -w): ceiling $((khz / 1000)) MHz -> $pass_log"

    make warm-stepup \
        DB_NAME="$DB_NAME" DIR="$DIR" REPEATS="$REPEATS" WARMUP="$WARMUP" \
        BATCH_SIZES="$BATCH_SIZES" RUNS="$RUNS" STATEMENT_TIMEOUT="$STATEMENT_TIMEOUT" \
        THERMAL_EQUALISE="$THERMAL_EQUALISE" T_LO="$T_LO" T_HI="$T_HI" \
        PREHEAT_MAX_S="$PREHEAT_MAX_S" COOLDOWN_MAX_S="$COOLDOWN_MAX_S" \
        FIX_CLOCK=1 CLOCK_MAX_KHZ="$khz" \
        > "$pass_log" 2>&1
    rc=$?
    t1=$(date +%s)
    dur=$(printf '%02d:%02d:%02d' $(( (t1 - t0) / 3600 )) $(( ((t1 - t0) % 3600) / 60 )) $(( (t1 - t0) % 60 )))

    run_dir="$(grep -o 'logs/warm_stepup/[0-9TZ]*-[0-9a-f]*' "$pass_log" | head -1)"
    [ -n "$run_dir" ] || run_dir="(not created)"
    if [ "$rc" = 0 ]; then
        ok=$((ok + 1)); status="ok"
        say "pass $pass done in $dur -> $run_dir"
    else
        failed=$((failed + 1)); status="FAILED(rc=$rc)"
        say "pass $pass FAILED (rc=$rc) after $dur; continuing with the next ceiling"
        tail -n 5 "$pass_log" | sed 's/^/    /'
    fi
    printf '%-6s %-10s %-20s %-9s %-8s %s\n' "$pass" "$khz" "$started" "$dur" "$status" "$run_dir" >> "$MANIFEST"

    # Idle gap: let the package settle so the next pass's gate starts from the
    # same place rather than from the previous pass's heat.
    if [ "$pass" -lt "$(echo $CLOCKS | wc -w)" ] && [ "$GAP_S" -gt 0 ]; then
        say "idling ${GAP_S}s before the next pass"
        sleep "$GAP_S"
    fi
done

say "sweep done: $ok ok, $failed failed"
say "manifest: $MANIFEST"
echo
cat "$MANIFEST"
