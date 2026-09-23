#!/usr/bin/env python3
"""
build_slope_sample.py - select and stage the two-tier slope-accuracy test.

Why: the batch-size cutoffs (how many copies a query needs before its fitted
per-copy energy is within 90 / 95 / 99 % of the truth) were derived from 53
TPC-H queries with 3 repeats, which leaves the reference slope as noisy as the
errors being measured and almost nothing above 75 J. This test fixes both:

  REFERENCE tier  4 queries per energy band, 10 repeats each, full step-up
                  1,2,4,8,16 with no cap. Their 10-repeat slope is the "true"
                  value; each single repeat is scored against the other nine.
  BREADTH tier    30 queries per band (36 in the two heavy bands), 3 repeats,
                  step-up 1..16 but the 16-copy batch is dropped for any query
                  whose warm single copy takes over 6 s. Used to measure how
                  overhead and noise vary across queries (pooled per band), and
                  to check the model validated on the reference tier.

Queries come from the SQLStorm pass (logs/sqlstorm, 2.5 GHz, 1 copy each):
only queries that passed, whose single copy took <= 13.5 s. Bands are on that
run's single-copy package energy. Within a band the picks are spread evenly
over the band's energy range (systematic stratified sampling on rank) and
alternate between 4-worker and lighter plans where the band allows.

Outputs (files are COPIED, the SQLStorm folder is untouched):
  queries/tpch/sqlstorm_slope/reference/*.sql, .../breadth/*.sql
  logs/slope_sample/manifest.csv                one row per selected query
  logs/slope_sample/order_reference.txt         each query x10, shuffled
  logs/slope_sample/order_breadth.txt           each query x3, shuffled
The order files are replayed by run_warm_stepup.sh (ORDER_FILE=...), where a
repeated line is a repeat. Run both tiers with test/run_slope_sample.sh.

  python3 test/build_slope_sample.py [--seed 20260922] [--force]
"""
import argparse
import collections
import csv
import math
import os
import random
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_LOGS = os.path.join(ROOT, "logs/sqlstorm")
SRC_DIR = "queries/tpch/SQLStorm"
OUT_Q = "queries/tpch/sqlstorm_slope"
OUT_LOGS = "logs/slope_sample"

BANDS = [(0, 2), (2, 7.5), (7.5, 15), (15, 40), (40, 75), (75, 120), (120, math.inf)]
REF_PER_BAND = 4
REF_REPEATS = 10
BREADTH_PER_BAND = [30, 30, 30, 30, 30, 36, 36]
BREADTH_REPEATS = 3
MAX_T1 = 13.5            # s, single copy at 2.5 GHz
CAP_SEC = 6.0            # breadth tier: drop N=16 when the warm copy exceeds this

# Cost model, calibrated on the 2.5 GHz TPC-H step-up (20260918T224909Z-a543de):
# restart + ready + parse 4.26 s, gate 1.55 s, cold warm-up extra 3.0 s, two
# warm-ups, and each batch of N copies = ratio[N] x single copy.
RATIO = {1: 1.0, 2: 1.77, 4: 3.27, 8: 6.31, 16: 12.34}


def entry_seconds(t1, sizes):
    return 4.26 + 1.55 + 3.0 + 2 * t1 + sum(RATIO[n] for n in sizes) * t1


def band_label(lo, hi):
    return f"{lo:g}-{hi:g} J" if hi != math.inf else f">{lo:g} J"


def load_candidates():
    moved = set()
    for name in ("moved_timeouts.txt", "moved_errors.tsv"):
        path = os.path.join(SRC_LOGS, name)
        if os.path.exists(path):
            moved |= {l.split("\t")[0].strip() for l in open(path) if l.strip()}
    workers = collections.defaultdict(int)
    for r in csv.DictReader(open(os.path.join(SRC_LOGS, "query_samples_tpch_idx.csv"))):
        if r["phase"] == "measured" and r["workers_launched"]:
            workers[r["query"]] = max(workers[r["query"]], int(r["workers_launched"]))
    cand = {}
    for r in csv.DictReader(open(os.path.join(SRC_LOGS, "query_timing_tpch_idx.csv"))):
        q = r["query"]
        if r["phase"] != "measured" or r["failed"] == "1" or q in moved or not r["rapl_pkg_j"]:
            continue
        t1 = float(r["elapsed_sec"])
        if t1 > MAX_T1 or not os.path.exists(os.path.join(ROOT, q)):
            continue
        cand[q] = {"e1": float(r["rapl_pkg_j"]), "t1": t1, "workers": workers.get(q, 0)}
    return cand


def spread_pick(pool, k, rnd, exclude=()):
    """k picks spread over the pool's energy ranks: one per equal slice, random
    within the slice, alternating 4-worker / lighter plans where possible."""
    pool = sorted((q for q in pool if q[0] not in exclude), key=lambda x: x[1]["e1"])
    if len(pool) <= k:
        return pool
    out = []
    for i in range(k):
        sl = pool[round(i * len(pool) / k): round((i + 1) * len(pool) / k)]
        want_heavy = (i % 2 == 0)
        pref = [x for x in sl if (x[1]["workers"] >= 4) == want_heavy]
        out.append(rnd.choice(pref or sl))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=20260922)
    ap.add_argument("--force", action="store_true", help="replace an existing staged sample")
    a = ap.parse_args()
    os.chdir(ROOT)

    if os.path.exists(OUT_Q) and not a.force:
        sys.exit(f"{OUT_Q} already exists; use --force to rebuild it")
    rnd = random.Random(a.seed)
    cand = load_candidates()
    print(f"candidates: {len(cand)} passing SQLStorm queries with a single copy <= {MAX_T1} s")

    rows = []
    for bi, (lo, hi) in enumerate(BANDS):
        pool = [(q, v) for q, v in cand.items() if lo <= v["e1"] < hi]
        ref = spread_pick(pool, REF_PER_BAND, rnd)
        breadth = spread_pick(pool, BREADTH_PER_BAND[bi], rnd, exclude={q for q, _ in ref})
        for tier, sel, reps in (("reference", ref, REF_REPEATS), ("breadth", breadth, BREADTH_REPEATS)):
            for q, v in sel:
                rows.append(dict(tier=tier, band=band_label(lo, hi), query=q, e1_j=v["e1"], t1_s=v["t1"],
                                 workers=v["workers"], repeats=reps,
                                 staged=f"{OUT_Q}/{tier}/{os.path.basename(q)}"))

    if os.path.exists(OUT_Q):
        shutil.rmtree(OUT_Q)
    for tier in ("reference", "breadth"):
        os.makedirs(f"{OUT_Q}/{tier}", exist_ok=True)
    os.makedirs(OUT_LOGS, exist_ok=True)
    for r in rows:
        shutil.copy2(r["query"], r["staged"])

    with open(f"{OUT_LOGS}/manifest.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)

    total_h = {}
    for tier in ("reference", "breadth"):
        sel = [r for r in rows if r["tier"] == tier]
        order = [r["staged"] for r in sel for _ in range(r["repeats"])]
        rnd.shuffle(order)
        with open(f"{OUT_LOGS}/order_{tier}.txt", "w") as f:
            f.write(f"# slope sample, {tier} tier: {len(sel)} queries, seed {a.seed}\n")
            f.write("# one line per entry; a repeated line is a repeat (run_warm_stepup.sh ORDER_FILE)\n")
            f.write("\n".join(order) + "\n")
        cap = tier == "breadth"
        sec = sum(r["repeats"] * entry_seconds(r["t1_s"], (1, 2, 4, 8) if cap and r["t1_s"] > CAP_SEC
                                               else (1, 2, 4, 8, 16)) for r in sel)
        total_h[tier] = sec / 3600
        print(f"{tier:9s} {len(sel):3d} queries, {len(order):4d} entries, estimated {sec / 3600:5.1f} h")

    print(f"{'band':>11s} {'ref':>4s} {'breadth':>8s}  breadth keeping N=16")
    for lo, hi in BANDS:
        b = band_label(lo, hi)
        ref = [r for r in rows if r["band"] == b and r["tier"] == "reference"]
        br = [r for r in rows if r["band"] == b and r["tier"] == "breadth"]
        print(f"{b:>11s} {len(ref):4d} {len(br):8d}  {sum(1 for r in br if r['t1_s'] <= CAP_SEC):4d}")
    print(f"estimated total {sum(total_h.values()):.1f} h")


if __name__ == "__main__":
    main()
