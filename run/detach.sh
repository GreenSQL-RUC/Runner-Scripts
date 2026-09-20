#!/usr/bin/env bash
#
# detach.sh - run a long benchmark job unattended, detached from the terminal
# (or the Claude session) that started it, with suspend blocked until it ends.
#
#   setsid nohup bash run/detach.sh <console.log> <command...> > /dev/null 2>&1 < /dev/null &
#
# Example:
#   setsid nohup bash run/detach.sh logs/sqlstorm/console.log \
#       make run DB_NAME=tpch_idx DIR=queries/tpch/SQLStorm WARMUP=1 BATCH_SIZES=1 \
#       > /dev/null 2>&1 < /dev/null &
#
# What it adds around <command>:
#   - an "idle" inhibitor (a normal user may take it) and a root-held
#     "sleep:handle-lid-switch" inhibitor, so a laptop neither idles into
#     suspend nor suspends on lid close while the job runs. Both are released
#     the moment the job exits;
#   - one console log with a start line, the command's full output, and an end
#     line carrying the exit code and the wall-clock duration.
#
# The machine itself must stay powered on. Closing the terminal, the Claude app
# or an SSH session does not stop the job; `kill <pid>` of the make process does
# (make targets that pin the clock restore it on TERM).
#
# ENV: SUDO_PASSWORD (default a, same as the Makefile)
#
set -uo pipefail

[ $# -ge 2 ] || { echo "usage: $0 <console.log> <command...>" >&2; exit 2; }
LOG="$1"; shift

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$HERE")" || exit 1

# Re-exec once under the user-level idle inhibitor.
if [ -z "${DETACH_INHIBITED:-}" ] && command -v systemd-inhibit >/dev/null 2>&1; then
    export DETACH_INHIBITED=1
    exec systemd-inhibit --what=idle --who="GreenSQL detached job" \
         --why="benchmark in progress" --mode=block bash "$0" "$LOG" "$@"
fi

mkdir -p "$(dirname "$LOG")"
exec >> "$LOG" 2>&1

# Suspend and lid-close need root; a helper holds that inhibitor for exactly as
# long as this script lives.
printf '%s\n' "${SUDO_PASSWORD:-a}" | sudo -S -v 2>/dev/null
INHIBIT_PID=""
if command -v systemd-inhibit >/dev/null 2>&1; then
    sudo -n systemd-inhibit --what=sleep:handle-lid-switch \
        --who="GreenSQL detached job" --why="benchmark in progress" --mode=block \
        bash -c "while kill -0 $$ 2>/dev/null; do sleep 30; done" >/dev/null 2>&1 &
    INHIBIT_PID=$!
fi
trap '[ -n "$INHIBIT_PID" ] && kill "$INHIBIT_PID" 2>/dev/null' EXIT

t0=$(date +%s)
echo "===== detach.sh start $(date -u +%Y-%m-%dT%H:%M:%SZ)  pid $$"
echo "===== command: $*"
echo "===== suspend inhibited: $([ -n "$INHIBIT_PID" ] && echo yes || echo NO)"
"$@"
rc=$?
t1=$(date +%s)
printf '===== detach.sh end %s  exit %d  duration %02d:%02d:%02d\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" \
    $(( (t1 - t0) / 3600 )) $(( ((t1 - t0) % 3600) / 60 )) $(( (t1 - t0) % 60 ))
exit $rc
