#!/usr/bin/env python3
"""match_power.py - line the background power log (run/power_logger.py) up with
the batches and idle baselines of a run, by time.

  python3 compare/match_power.py <run_dir> <power_dir> [--lag S] [--out FILE]

<run_dir> is a warm step-up results folder (query_timing_<db>.csv and
query_idle_<db>.csv with start_epoch / end_epoch, i.e. made by a query_runner
from 2026-10-14 on); <power_dir> holds the power_<host>_<hour>Z.csv files of
the same node. Both are only read. Writes <run_dir>/power_match_<db>.csv (or
--out; it refuses to replace an input or any file other than an earlier
match), one row per measured batch and per idle baseline:

  kind, query, phase, batch_index, batchnum, start_epoch, end_epoch, elapsed_sec,
  rapl_pkg_j, rapl_dram_j,     from the run (the runner's own, exact window;
  rapl_psys_j                  psys blank before 2026-10-15 or without psys)
  bmc_n                        BMC readings inside the window (shifted by --lag)
  bmc_mean_w, bmc_j            their mean, and mean x elapsed_sec
  bmc_nearest_w                the reading nearest the window's middle (for
                               windows too short to hold a reading)
  <zone>_j_1hz                 each logged RAPL zone (package-0, dram, psys...)
                               over the window, interpolated from the 1 Hz
                               counters: a cross-check of the runner's values,
                               and psys, which the runner does not record

The BMC averages inside itself and answers about once a second, so a reading
taken at time t describes roughly the second before t, plus whatever delay
the BMC adds: --lag (default 1.0 s) shifts the window later by that much.
Find the BMC's delay once per node type by logging a known step (e.g.
`sleep 20; stress-ng --cpu 0 -t 20`) and seeing where bmc_w moves. Batches
shorter than a few seconds get one or no BMC reading: use them only in
aggregate (e.g. sum of bmc_j over many batches against the sum of elapsed
time), never one by one.
"""
import argparse
import bisect
import csv
import glob
import os
import re
import sys


def load_power(power_dir):
    rows, ranges = [], {}
    for path in sorted(glob.glob(os.path.join(power_dir, "power_*.csv"))):
        with open(path) as f:
            lines = f.read().splitlines()
        for ln in lines:
            if ln.startswith("#"):
                for name, r in re.findall(r"(\S+)=(\d+)", ln):
                    ranges["uj_" + name] = float(r)
        rows += list(csv.DictReader(ln for ln in lines if not ln.startswith("#")))
    rows = [r for r in rows if r.get("epoch")]
    rows.sort(key=lambda r: float(r["epoch"]))
    return rows, ranges


def series(rows, col, wrap):
    """(epochs, cumulative joules) for one RAPL column, wraps undone."""
    ts, js, off, prev = [], [], 0.0, None
    for r in rows:
        v = r.get(col, "")
        if v == "":
            continue
        v = float(v)
        if prev is not None and v < prev and wrap:
            off += wrap
        prev = v
        ts.append(float(r["epoch"]))
        js.append((v + off) * 1e-6)
    return ts, js


def interp(ts, ys, t):
    i = bisect.bisect_left(ts, t)
    if i == 0 or i >= len(ts):
        return None                                    # outside the log
    t0, t1 = ts[i - 1], ts[i]
    return ys[i - 1] + (ys[i] - ys[i - 1]) * (t - t0) / (t1 - t0)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir")
    ap.add_argument("power_dir")
    ap.add_argument("--lag", type=float, default=1.0, help="BMC delay in seconds (default 1.0)")
    ap.add_argument("--out")
    a = ap.parse_args()

    timing = glob.glob(os.path.join(a.run_dir, "query_timing_*.csv"))
    if len(timing) != 1:
        sys.exit("expected one query_timing_<db>.csv in %s" % a.run_dir)
    db = os.path.basename(timing[0])[len("query_timing_"):-4]
    prow, ranges = load_power(a.power_dir)
    if not prow:
        sys.exit("no power_*.csv rows in %s" % a.power_dir)
    bmc = [(float(r["epoch"]), float(r["bmc_w"])) for r in prow if r.get("bmc_w")]
    bt = [t for t, _ in bmc]
    zones = [c for c in prow[0] if c.startswith("uj_")]
    zs = {c: series(prow, c, ranges.get(c)) for c in zones}

    windows = []
    for r in csv.DictReader(open(timing[0])):
        if r.get("phase") != "measured":
            continue
        windows.append(dict(kind="batch", query=r["query"], phase=r["phase"], batch_index=r["batch_index"],
                            batchnum=r["batchnum"], start_epoch=r.get("start_epoch", ""), end_epoch=r.get("end_epoch", ""),
                            elapsed_sec=r["elapsed_sec"], rapl_pkg_j=r["rapl_pkg_j"], rapl_dram_j=r["rapl_dram_j"],
                            rapl_psys_j=r.get("rapl_psys_j", "")))
    idle = os.path.join(a.run_dir, "query_idle_%s.csv" % db)
    if os.path.exists(idle):
        for r in csv.DictReader(open(idle)):
            el = float(r["idle_s"])
            pkg = "%.3f" % (float(r["idle_pkg_w"]) * el) if r["idle_pkg_w"] else ""
            dram = "%.3f" % (float(r["idle_dram_w"]) * el) if r["idle_dram_w"] else ""
            psys = "%.3f" % (float(r["idle_psys_w"]) * el) if r.get("idle_psys_w") else ""
            windows.append(dict(kind="idle", query=r["query"], phase="idle", batch_index="", batchnum="",
                                start_epoch=r.get("start_epoch", ""), end_epoch=r.get("end_epoch", ""),
                                elapsed_sec=r["idle_s"], rapl_pkg_j=pkg, rapl_dram_j=dram, rapl_psys_j=psys))
    if not any(w["start_epoch"] for w in windows):
        sys.exit("%s has no start_epoch/end_epoch columns (made by an older query_runner); "
                 "it cannot be matched" % timing[0])

    # The inputs are only read. The one file written is the match; it never
    # replaces an input or any file that is not an earlier match.
    out = a.out or os.path.join(a.run_dir, "power_match_%s.csv" % db)
    inputs = {os.path.realpath(p) for p in [timing[0], idle] + glob.glob(os.path.join(a.power_dir, "power_*.csv"))}
    if os.path.realpath(out) in inputs:
        sys.exit("refusing to write over an input file: %s" % out)
    if os.path.exists(out) and not os.path.basename(out).startswith("power_match"):
        sys.exit("refusing to overwrite %s (not an earlier power_match file); pick another --out" % out)
    cols = list(windows[0]) + ["bmc_n", "bmc_mean_w", "bmc_j", "bmc_nearest_w"] + \
        ["%s_j_1hz" % c[3:] for c in zones]
    covered = 0
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(cols)
        for win in windows:
            row = [win[k] for k in windows[0]]
            if not win["start_epoch"]:
                w.writerow(row + [""] * (len(cols) - len(row)))
                continue
            s, e = float(win["start_epoch"]), float(win["end_epoch"])
            lo, hi = bisect.bisect_right(bt, s + a.lag), bisect.bisect_right(bt, e + a.lag)
            vals = [bmc[i][1] for i in range(lo, hi)]
            mean = sum(vals) / len(vals) if vals else None
            near = ""
            if bt:
                mid = (s + e) / 2 + a.lag
                i = min(range(max(0, lo - 1), min(len(bt), hi + 1)), key=lambda k: abs(bt[k] - mid))
                if abs(bt[i] - mid) <= 1.5:
                    near = "%.0f" % bmc[i][1]
            row += [len(vals), "%.1f" % mean if vals else "", "%.3f" % (mean * (e - s)) if vals else "", near]
            for c in zones:
                ts, js = zs[c]
                j0, j1 = interp(ts, js, s), interp(ts, js, e)
                row.append("%.3f" % (j1 - j0) if j0 is not None and j1 is not None else "")
            covered += bool(vals) or bool(near)
            w.writerow(row)
    print("%s: %d windows (%d batches, %d idle), %d with a BMC reading; lag %.1f s"
          % (out, len(windows), sum(x["kind"] == "batch" for x in windows),
             sum(x["kind"] == "idle" for x in windows), covered, a.lag))


if __name__ == "__main__":
    main()
