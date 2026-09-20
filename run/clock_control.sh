#!/usr/bin/env bash
#
# clock_control.sh - pin the CPU clock for a measurement run, and put it back.
#
# "Fix clock" = cap the core frequency and set the performance governor, so it
# no longer follows the die temperature (the boost margin is what turns thermal
# carry-over into timing/energy noise; see thermal_runner_brief.md section 3b).
# Only the small leakage term remains temperature-dependent.
#
# By default the cap is the base (non-turbo) frequency: turbo is disabled and
# nothing else is touched. CLOCK_MAX_KHZ pins to an explicit ceiling instead:
#
#   CLOCK_MAX_KHZ=2100000 bash clock_control.sh apply
#
# A ceiling ABOVE the base frequency is inside the turbo range, so turbo is left
# ENABLED and scaling_max_freq does the capping; at or below base, turbo is
# disabled as well. Either way scaling_min_freq is left alone, so an idle core
# still drops to its minimum exactly as in the default mode.
#
# NOTE: a frequency cap is a ceiling, not a guarantee. Package power limits
# (RAPL PL1) and thermal throttling can still hold the cores below it, which on
# a laptop is common once several cores are busy.
#
#   bash clock_control.sh apply   [statefile]   # save current values, pin
#   bash clock_control.sh restore [statefile]   # put the saved values back
#   bash clock_control.sh status               # print the current settings
#   bash clock_control.sh with <command...>     # apply, run, restore (also on Ctrl-C)
#
# ENV: CLOCK_MAX_KHZ  explicit ceiling in kHz (e.g. 2100000); unset = base freq.
#
# Needs root for apply/restore. If the sysfs knobs are missing (VM, non-Intel),
# apply prints what it skipped and exits 0, so a run continues un-pinned but
# the status lines in summary.txt say so.
#
set -uo pipefail

MODE="${1:-status}"
STATE="${2:-/tmp/greensql_clock_state}"

NO_TURBO=/sys/devices/system/cpu/intel_pstate/no_turbo
BOOST=/sys/devices/system/cpu/cpufreq/boost
GOV_GLOB=/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor
MAXF_GLOB=/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_max_freq
CPU0=/sys/devices/system/cpu/cpu0/cpufreq
CLOCK_MAX_KHZ="${CLOCK_MAX_KHZ:-}"

# Base (non-turbo) frequency; empty when the platform does not publish it.
base_khz() { cat "$CPU0/base_frequency" 2>/dev/null || true; }
# Highest frequency the hardware will accept (turbo ceiling).
hw_max_khz() { cat "$CPU0/cpuinfo_max_freq" 2>/dev/null || true; }

status() {
    local nt="n/a" gov="n/a" minf="n/a" maxf="n/a"
    [ -r "$NO_TURBO" ] && nt="$(cat "$NO_TURBO")"
    [ -r "$BOOST" ] && nt="boost=$(cat "$BOOST")"
    [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ] && gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
    [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq ] && minf="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq)"
    [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq ] && maxf="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)"
    echo "no_turbo: $nt"
    echo "governor: $gov"
    echo "min_freq_khz: $minf"
    echo "max_freq_khz: $maxf"
}

apply() {
    [ "$(id -u)" = 0 ] || { echo "clock_control: apply needs root; clock NOT pinned" >&2; return 0; }
    # Save what we are about to change so restore can undo exactly that.
    : > "$STATE"

    local base hwmax want_turbo=0
    base="$(base_khz)"; hwmax="$(hw_max_khz)"
    if [ -n "$CLOCK_MAX_KHZ" ]; then
        case "$CLOCK_MAX_KHZ" in
            ''|*[!0-9]*) echo "clock_control: CLOCK_MAX_KHZ must be an integer in kHz, got \"$CLOCK_MAX_KHZ\"" >&2; return 1 ;;
        esac
        if [ -n "$hwmax" ] && [ "$CLOCK_MAX_KHZ" -gt "$hwmax" ]; then
            echo "clock_control: CLOCK_MAX_KHZ=$CLOCK_MAX_KHZ is above the hardware maximum $hwmax; refusing" >&2
            return 1
        fi
        # Above base = a turbo bin, which is only reachable with turbo enabled.
        [ -n "$base" ] && [ "$CLOCK_MAX_KHZ" -gt "$base" ] && want_turbo=1
    fi

    if [ -w "$NO_TURBO" ]; then
        echo "no_turbo=$(cat "$NO_TURBO")" >> "$STATE"
        if [ "$want_turbo" = 1 ]; then
            echo 0 > "$NO_TURBO" && echo "clock_control: no_turbo=0 (ceiling ${CLOCK_MAX_KHZ} kHz is a turbo bin)"
        else
            echo 1 > "$NO_TURBO" && echo "clock_control: no_turbo=1"
        fi
    elif [ -w "$BOOST" ]; then
        echo "boost=$(cat "$BOOST")" >> "$STATE"
        if [ "$want_turbo" = 1 ]; then
            echo 1 > "$BOOST" && echo "clock_control: boost=1 (ceiling ${CLOCK_MAX_KHZ} kHz needs boost)"
        else
            echo 0 > "$BOOST" && echo "clock_control: boost=0"
        fi
    else
        echo "clock_control: no turbo knob found (intel_pstate/no_turbo or cpufreq/boost); skipped"
    fi
    local g0
    g0="$(cat "$CPU0/scaling_governor" 2>/dev/null || true)"
    if [ -n "$g0" ]; then
        echo "governor=$g0" >> "$STATE"
        for g in $GOV_GLOB; do echo performance > "$g" 2>/dev/null; done
        echo "clock_control: governor=performance (was $g0)"
    else
        echo "clock_control: no cpufreq governor found; skipped"
    fi

    # Explicit ceiling: every logical CPU gets the same scaling_max_freq. Saved
    # per CPU so restore is exact even if they differed.
    if [ -n "$CLOCK_MAX_KHZ" ]; then
        local wrote=0 f cpu got
        for f in $MAXF_GLOB; do
            cpu="${f%/cpufreq/scaling_max_freq}"; cpu="${cpu##*/}"
            echo "max_freq:$cpu=$(cat "$f" 2>/dev/null)" >> "$STATE"
            echo "$CLOCK_MAX_KHZ" > "$f" 2>/dev/null && wrote=$((wrote + 1))
        done
        got="$(cat "$CPU0/scaling_max_freq" 2>/dev/null || true)"
        if [ "$wrote" = 0 ]; then
            echo "clock_control: scaling_max_freq not writable; ceiling NOT applied" >&2
        elif [ "$got" != "$CLOCK_MAX_KHZ" ]; then
            # intel_pstate rounds to the nearest P-state bin (100 MHz steps).
            echo "clock_control: max_freq requested $CLOCK_MAX_KHZ kHz, hardware took $got kHz on $wrote CPUs"
        else
            echo "clock_control: max_freq=$CLOCK_MAX_KHZ kHz on $wrote CPUs"
        fi
    fi
}

restore() {
    [ -f "$STATE" ] || { echo "clock_control: no saved state ($STATE); nothing to restore"; return 0; }
    [ "$(id -u)" = 0 ] || { echo "clock_control: restore needs root" >&2; return 0; }
    local cpu
    while IFS='=' read -r k v; do
        case "$k" in
            no_turbo) echo "$v" > "$NO_TURBO" 2>/dev/null && echo "clock_control: no_turbo restored to $v" ;;
            boost)    echo "$v" > "$BOOST" 2>/dev/null && echo "clock_control: boost restored to $v" ;;
            governor) for g in $GOV_GLOB; do echo "$v" > "$g" 2>/dev/null; done; echo "clock_control: governor restored to $v" ;;
            max_freq:*) cpu="${k#max_freq:}"
                        echo "$v" > "/sys/devices/system/cpu/$cpu/cpufreq/scaling_max_freq" 2>/dev/null
                        [ "$cpu" = cpu0 ] && echo "clock_control: max_freq restored to $v kHz" ;;
        esac
    done < "$STATE"
    rm -f "$STATE"
}

case "$MODE" in
    status)  status ;;
    apply)   apply ;;
    restore) restore ;;
    with)
        shift
        STATE="/tmp/greensql_clock_state.$$"
        trap 'restore' EXIT INT TERM
        apply
        "$@"
        rc=$?
        exit $rc
        ;;
    *) echo "usage: $0 {status|apply|restore|with <command...>} [statefile]" >&2; exit 2 ;;
esac
