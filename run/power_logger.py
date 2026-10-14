#!/usr/bin/env python3
"""power_logger.py - background power log: the node's BMC (Dell iDRAC, or any
BMC with DCMI) plus the RAPL counters, sampled about once a second and
timestamped, for matching with the benchmark runs afterwards.

The BMC reads the power-supply input of the whole node (CPU, memory, disks,
NICs, fans, PSU losses) - what RAPL cannot see - but only about once a second,
and the reading is itself averaged inside the BMC. So it is not attributed to
batches while they run: it is logged on its own, and compare/match_power.py
lines it up with the start_epoch / end_epoch of each batch and idle baseline
later. The RAPL counters (package, dram, psys where present) are logged with
it, so the two can be compared over the same seconds.

  sudo python3 run/power_logger.py <out_dir> [interval_s]   # log until stopped
  sudo python3 run/power_logger.py --check                  # one reading, then exit

One CSV per UTC hour, <out_dir>/power_<host>_<YYYYMMDDTHH>Z.csv, so finished
hours never change again (the log saving and pushing copy only what changed).
Columns:
  epoch            Unix seconds when the BMC was asked (ms); the reading
                   describes the time just before it
  timestamp_utc    the same, readable
  call_ms          how long the BMC took to answer
  bmc_w            DCMI "Instantaneous power reading" (W)
  bmc_avg_w, bmc_min_w, bmc_max_w, bmc_period_s
                   DCMI average / min / max over the BMC's sampling period
                   (some BMCs report since-reset statistics here, with a very
                   long period; then only bmc_w is useful)
  uj_<zone>        raw RAPL powercap counters (microjoules, cumulative; wrap at
                   the zone's max_energy_range_uj, listed in the header
                   comment of each file). Differences give energy over any
                   window; on the m510 the kernel's dram value is 4x high
                   (see fix_dram_unit in run/rapl.c), the c6620 is not affected.

Runs as root (energy_uj and /dev/ipmi0 are root-only); the files are handed to
the owner of <out_dir>'s parent, so the repository's user can read and move
them. ENV: IPMITOOL (default ipmitool).
"""
import datetime as dt
import glob
import os
import re
import socket
import subprocess
import sys
import time

IPMITOOL = os.environ.get("IPMITOOL", "ipmitool")
FIELDS = {
    "bmc_w": r"Instantaneous power reading:\s*(\d+)",
    "bmc_min_w": r"Minimum during sampling period:\s*(\d+)",
    "bmc_max_w": r"Maximum during sampling period:\s*(\d+)",
    "bmc_avg_w": r"Average power reading over sample period:\s*(\d+)",
    "bmc_period_s": r"Sampling period:\s*(\d+)",
}
BMC_COLS = ["bmc_w", "bmc_avg_w", "bmc_min_w", "bmc_max_w", "bmc_period_s"]


def bmc_reading():
    """One DCMI power reading: ({field: value}, call seconds, error text)."""
    t0 = time.monotonic()
    try:
        p = subprocess.run([IPMITOOL, "dcmi", "power", "reading"], capture_output=True,
                           text=True, timeout=10)
        out, err = p.stdout, (p.stderr.strip() or "exit %d" % p.returncode) if p.returncode else ""
    except (OSError, subprocess.TimeoutExpired) as e:
        out, err = "", str(e)
    took = time.monotonic() - t0
    vals = {}
    for k, rx in FIELDS.items():
        m = re.search(rx, out)
        if m:
            vals[k] = int(m.group(1))
    if "bmc_w" not in vals and not err:
        err = "no power reading in the output: " + out.strip()[:200]
    return vals, took, err


def rapl_zones():
    """[(column, energy_uj path, max_energy_range_uj)] for intel-rapl zones."""
    zones = []
    for z in sorted(glob.glob("/sys/class/powercap/intel-rapl:*")):
        try:
            name = open(z + "/name").read().strip()
            rng = open(z + "/max_energy_range_uj").read().strip()
            open(z + "/energy_uj").read()
        except OSError:
            continue
        col = "uj_" + name
        if any(c == col for c, _, _ in zones):         # a second package: package-1 etc.
            col += "_" + os.path.basename(z).split(":", 1)[1]
        zones.append((col, z + "/energy_uj", rng))
    return zones


def read_uj(path):
    try:
        return open(path).read().strip()
    except OSError:
        return ""


def give_to_owner(path, ref):
    try:
        st = os.stat(ref)
        os.chown(path, st.st_uid, st.st_gid)
    except OSError:
        pass


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--check":
        vals, took, err = bmc_reading()
        if err:
            print("BMC power reading FAILED (%s)" % err)
        else:
            print("BMC power reading %d W (avg %s W over %s s; answered in %.0f ms)"
                  % (vals["bmc_w"], vals.get("bmc_avg_w", "?"), vals.get("bmc_period_s", "?"), took * 1000))
        for col, path, rng in rapl_zones():
            print("RAPL %-16s %s uJ (wraps at %s)" % (col[3:], read_uj(path), rng))
        sys.exit(1 if err else 0)

    if len(sys.argv) < 2:
        sys.exit(__doc__)
    out_dir = os.path.abspath(sys.argv[1])
    interval = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
    os.makedirs(out_dir, exist_ok=True)
    owner_ref = os.path.dirname(out_dir)
    give_to_owner(out_dir, owner_ref)
    host = socket.gethostname().split(".")[0]
    zones = rapl_zones()
    cols = ["epoch", "timestamp_utc", "call_ms"] + BMC_COLS + [c for c, _, _ in zones]

    f, hour, errors = None, None, 0
    nxt = time.monotonic()
    while True:
        t = time.time()
        vals, took, err = bmc_reading()
        uj = [read_uj(p) for _, p, _ in zones]
        now = dt.datetime.fromtimestamp(t, dt.timezone.utc)
        h = now.strftime("%Y%m%dT%H")
        if h != hour:
            if f:
                f.close()
            path = os.path.join(out_dir, "power_%s_%sZ.csv" % (host, h))
            new = not os.path.exists(path) or os.path.getsize(path) == 0
            f = open(path, "a", buffering=1)
            if new:
                f.write("# power_logger.py on %s, interval %.1f s; RAPL wrap ranges (uJ): %s\n"
                        % (host, interval, " ".join("%s=%s" % (c[3:], r) for c, _, r in zones) or "none"))
                f.write(",".join(cols) + "\n")
            give_to_owner(path, owner_ref)
            hour = h
        if err:
            errors += 1
            if errors <= 5 or errors % 600 == 0:
                print("%s BMC reading failed (%d so far): %s" % (now.isoformat(), errors, err), file=sys.stderr)
        row = ["%.3f" % t, now.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z", "%.0f" % (took * 1000)]
        row += [str(vals.get(k, "")) for k in BMC_COLS] + uj
        f.write(",".join(row) + "\n")
        # Fixed cadence; a slow BMC answer skips ticks rather than bunching them.
        nxt += interval
        delay = nxt - time.monotonic()
        if delay < 0:
            nxt = time.monotonic() + interval
            delay = interval
        time.sleep(delay)


if __name__ == "__main__":
    main()
