#!/usr/bin/env bash
#
# run_compare.sh [session] - one session of the cross-laptop comparison test.
#
# The fixed set in compare/set/order.txt (50 SQLStorm StackOverflow queries,
# 10 per warm 1-copy time band 0.1-6 s, + 4 synthetic probes, x 6 rounds, each
# round a fresh shuffle) as a (1,16) warm step-up: per entry a cold start
# (drop caches + restart), the 40-60 C thermal gate, 2 warm-ups, a 5 s idle
# baseline, then N=1 and N=16; 15 s statement timeout, and a failed warm-up skips
# the measured batches. ~3.3 h on a Latitude 7490. Every machine replays the SAME
# order file, so sessions differ only by machine and time. Rebuild the set with
# compare/build_compare_set.py (never per machine).
#
# What it does:
#   1. pre-flight: PostgreSQL $PGVER at $PG_MINOR, stackoverflow_1gb present,
#      every query in the set present, no other runner active;
#   2. applies the testing parameters (make set-parameters);
#   3. pauses automatic upgrades (stops apt-daily.timer / apt-daily-upgrade.timer
#      if active, waits for any apt/dpkg in progress); the timers it stopped are
#      started again on exit, so a box with them disabled stays disabled;
#   4. make warm-stepup with the gate (T_LO=40 T_HI=60) and the clock pinned at
#      2.5 GHz (FIX_CLOCK=1, performance governor; restored afterwards);
#   5. checks from the run's own CSVs that every entry ran at 2.5 GHz with the
#      performance governor on PG $PG_MINOR, and how many entries the gate let
#      start outside 40-60 C; prints CHECK OK / CHECK FAILED.
#
# Results: logs/compare/warm_stepup/compare_<host>_<session>_<stamp>/ (timing,
# samples, idle, runinfo CSVs, run order, console.log, summary.txt). The round of
# an entry is its position in the order: entries 1-54 are round 1, and so on.
#
# Run as user01 (sudo is primed from SUDO_PASSWORD, default a). Detached:
#   setsid nohup bash run/detach.sh logs/compare/console_s1.log \
#       bash compare/run_compare.sh s1 > /dev/null 2>&1 < /dev/null &
# Stop it: sudo kill -TERM -- -<pgid> (the process group is printed at the start).
#
# ENV: ENTRIES=N   run only the first N entries (smoke test; RUNID gets "smoke_")
#      PGVER       PostgreSQL major to test (default 18; a CloudLab node from
#                  cloudlab/profile.py sets it in login shells). The laptop
#                  sessions are PG18; another major gets "pg<N>_" in its RUNID.
#      PG_MINOR    required minor (default: build/bootstrap_ubuntu.sh's pin for
#                  PGVER, e.g. 18.6 or 16.15)
# The testing parameters a major lacks (io_* before PG18) are skipped by
# make set-parameters, so a PG16 session runs without them.
#
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SESSION="${1:-s1}"
ORDER=compare/set/order.txt
PGVER="${PGVER:-18}"
PG_MINOR="${PG_MINOR:-$(sed -n "s/^ *\[$PGVER\]=\([0-9.]*\)$/\1/p" build/bootstrap_ubuntu.sh)}"
CLOCK_KHZ=2500000
DB=stackoverflow_1gb
PW="${SUDO_PASSWORD:-a}"
ENTRIES="${ENTRIES:-}"
UNITS="apt-daily.timer apt-daily-upgrade.timer"

[ -n "$PG_MINOR" ] || { echo "!! no pinned minor for PG$PGVER in build/bootstrap_ubuntu.sh; set PG_MINOR" >&2; exit 1; }

as_root(){ printf '%s\n' "$PW" | sudo -S -p '' "$@"; }
die(){ echo "!! $*" >&2; exit 1; }

# --- 1. pre-flight -------------------------------------------------------------
[ -f "$ORDER" ] || die "missing $ORDER (python3 compare/build_compare_set.py)"
mapfile -t ENTRY < <(grep -vE '^\s*(#|$)' "$ORDER")
for q in $(printf '%s\n' "${ENTRY[@]}" | sort -u); do
    [ -f "$q" ] || die "query file missing: $q (make fetch-sqlstorm SQLSTORM_DATASET=stackoverflow)"
done
as_root true || die "sudo failed (set SUDO_PASSWORD)"
PORT=$(pg_lsclusters -h | awk -v v="$PGVER" '$1==v && $2=="main"{print $3}')
[ -n "$PORT" ] || die "no PG$PGVER main cluster"
psqlv(){ as_root -u postgres psql -p "$PORT" -d "$1" -Atc "$2"; }
ver=$(psqlv postgres "SHOW server_version" | awk '{print $1}')
[ "$ver" = "$PG_MINOR" ] || die "PG$PGVER is $ver, the test needs $PG_MINOR (sudo FORCE_MINOR=1 bash build/bootstrap_ubuntu.sh $PGVER)"
[ "$(psqlv postgres "SELECT 1 FROM pg_database WHERE datname='$DB'")" = 1 ] \
    || die "database $DB missing on PG$PGVER (make build-stackoverflow PGVER=$PGVER)"
busy=$(ps -eo pid=,stat=,comm= | awk '$2 !~ /^T/ && $3 ~ /^(query_runner|cold_runner|output_runner)$/')
[ -z "$busy" ] || die "another runner is active:
$busy"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
pgtag=""; [ "$PGVER" = 18 ] || pgtag="pg${PGVER}_"
RUNID="compare_$(hostname -s)_${pgtag}${SESSION}_$stamp"
if [ -n "$ENTRIES" ]; then
    RUNID="smoke_$RUNID"
    mkdir -p logs/compare
    sub="logs/compare/order_$RUNID.txt"
    { echo "# first $ENTRIES entries of $ORDER (smoke test)"; printf '%s\n' "${ENTRY[@]:0:$ENTRIES}"; } > "$sub"
    ORDER="$sub"
fi
RUN_DIR="logs/compare/warm_stepup/$RUNID"
echo "==> compare session $SESSION on $(hostname -s), PostgreSQL $ver: $RUNID"
echo "    $(grep -vcE '^\s*(#|$)' "$ORDER") entries from $ORDER; $(sed -n 's/^# estimate: //p' compare/set/order.txt)"
echo "    process group $(ps -o pgid= $$ | tr -d ' ')"

# --- 2. testing parameters -----------------------------------------------------
echo "==> testing parameters"
make --no-print-directory set-parameters PGVER="$PGVER" SUDO_PASSWORD="$PW" | grep -E "^(==>|  !!)|=" | sed 's/^/    /'

# --- 3. pause automatic upgrades ----------------------------------------------
stopped=""
resume_upgrades(){
    for u in $stopped; do as_root systemctl start "$u" && echo "==> resumed $u"; done
    stopped=""
}
trap resume_upgrades EXIT
trap 'exit 130' INT TERM
for u in $UNITS; do
    if systemctl is-active --quiet "$u"; then
        as_root systemctl stop "$u" && stopped="$stopped $u" && echo "==> paused $u"
    fi
done
# An upgrade in progress is apt/dpkg or /usr/bin/unattended-upgrade itself (not
# the always-running unattended-upgrade-shutdown helper).
apt_busy(){ pgrep -x 'apt|apt-get|dpkg' >/dev/null || pgrep -f '^/usr/bin/python3 /usr/bin/unattended-upgrade' >/dev/null; }
for _ in $(seq 1 60); do
    apt_busy || break
    echo "    waiting for a running apt/dpkg to finish..."; sleep 10
done
apt_busy && die "apt/dpkg still running after 10 min"

# --- 4. the run ---------------------------------------------------------------
make --no-print-directory warm-stepup SUDO_PASSWORD="$PW" \
    PGVER="$PGVER" DB_NAME="$DB" DIR=queries/stackoverflow/SQLStorm ORDER_FILE="$ORDER" \
    "BATCH_SIZES=1 16" WARMUP=2 RUNS=1 STATEMENT_TIMEOUT=15 WARMUP_FAIL_SKIP=1 \
    THERMAL_EQUALISE=1 T_LO=40 T_HI=60 FIX_CLOCK=1 CLOCK_MAX_KHZ="$CLOCK_KHZ" \
    IDLE_BASELINE_S=5 LOGS_DIR=logs/compare RUNID="$RUNID"
rc=$?
resume_upgrades

# --- 5. check the run against the protocol -------------------------------------
echo "==> checking $RUN_DIR"
python3 - "$RUN_DIR" "$DB" "$CLOCK_KHZ" "$PG_MINOR" <<'EOF'
import csv, os, sys
d, db, khz, pg = sys.argv[1:]
bad = []
info = list(csv.DictReader(open(os.path.join(d, f"query_runinfo_{db}.csv"))))
rows = list(csv.DictReader(open(os.path.join(d, f"query_timing_{db}.csv"))))
for k, want in (("scaling_max_khz", khz), ("governor", "performance"), ("pg_version", pg)):
    got = sorted({r[k] for r in info})
    print(f"    {k:16s} {', '.join(got)}")
    if got != [want]:
        bad.append(f"{k} not always {want}")
gate = [r for r in rows if r["phase"] == "warmup" and r["batch_index"] == "1"]
outside = [r for r in gate if r["pkg_temp_start_c"] and not 40 <= float(r["pkg_temp_start_c"]) <= 60]
print(f"    gate             {len(gate)} entries gated, {len(outside)} started outside 40-60 C")
skipped = sum(1 for r in gate if r["failed"] == "1")
meas = [r for r in rows if r["phase"] == "measured"]
print(f"    entries          {len(info)} run, {skipped} warm-up failures, "
      f"{sum(r['failed'] == '1' for r in meas)} failed measured batches")
if not gate:
    bad.append("no entries ran")
print("CHECK " + ("OK" if not bad else "FAILED: " + "; ".join(bad)))
EOF
exit $rc
