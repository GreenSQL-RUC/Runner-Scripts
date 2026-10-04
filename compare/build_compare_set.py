#!/usr/bin/env python3
"""
build_compare_set.py - choose the fixed query set for the cross-laptop
comparison test (compare/run_compare.sh).

The set is built ONCE and committed; every machine replays the same order file,
so the only things that differ between sessions are the machine and the time.

Selection, from laptop 1's 1-copy pass of SQLStorm StackOverflow
(logs/sqlstorm_stackoverflow, PG18, 2.5 GHz): queries that passed, PER_BAND per
warm 1-copy time band (0.1-6 s, five bands), spread evenly over each band's
energy range and alternating 4-worker / lighter plans (spread_pick from
test/build_slope_sample.py). Plus the four synthetic probes in compare/probes/
(CPU, memory bandwidth, memory latency, in-memory sort).

ROUNDS rounds: each round is every query once, in a fresh shuffle, so a drift
over the session shows up as a round effect. Round r is entries
(r-1)*n+1 .. r*n of the order file (n = queries per round); the "# round" lines
are comments the runner skips.

Outputs (committed):
  compare/set/manifest.csv   one row per query (band, laptop-1 t1/e1, workers)
  compare/set/order.txt      ROUNDS x every query, shuffled per round

  python3 compare/build_compare_set.py [--per-band 10] [--rounds 6] [--seed 20261001]
"""
import argparse
import collections
import csv
import glob
import os
import random
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "test"))
from build_slope_sample import spread_pick  # noqa: E402

SRC = "logs/sqlstorm_stackoverflow"
DB = "stackoverflow_1gb"
MAX_T1 = 14.0
OUT = "compare/set"
BANDS = [(0.1, 0.3), (0.3, 0.7), (0.7, 1.5), (1.5, 3.0), (3.0, 6.0)]   # warm 1-copy s
PROBE_T1 = 1.5          # rough 1-copy time of a probe at 2.5 GHz, for the estimate only
IDLE_S = 5              # IDLE_BASELINE_S in run_compare.sh


# Laptop cost of one (1,16) entry with the 40-60 C gate at 2.5 GHz, fitted on
# laptop 2's uniform run (1,752 entries): restart + gate + 2 warm-ups + N=1 +
# N=16, plus the idle baseline.
def entry_seconds(t1):
    return 4.22 + 17.65 * t1 + IDLE_S


def load_candidates():
    """Passing queries of laptop 1's 1-copy pass: query -> e1 (J), t1 (s), workers."""
    workers = collections.defaultdict(int)
    for r in csv.DictReader(open(os.path.join(ROOT, SRC, f"query_samples_{DB}.csv"))):
        if r["phase"] == "measured" and r["workers_launched"]:
            workers[r["query"]] = max(workers[r["query"]], int(r["workers_launched"]))
    cand = {}
    for r in csv.DictReader(open(os.path.join(ROOT, SRC, f"query_timing_{DB}.csv"))):
        if r["phase"] != "measured" or r["failed"] == "1" or not r["rapl_pkg_j"]:
            continue
        t1 = float(r["elapsed_sec"])
        if t1 <= MAX_T1 and os.path.exists(os.path.join(ROOT, r["query"])):
            cand[r["query"]] = {"e1": float(r["rapl_pkg_j"]), "t1": t1, "workers": workers.get(r["query"], 0)}
    return cand


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--per-band", type=int, default=10)
    ap.add_argument("--rounds", type=int, default=6)
    ap.add_argument("--seed", type=int, default=20261001)
    a = ap.parse_args()
    os.chdir(ROOT)
    rnd = random.Random(a.seed)
    cand = load_candidates()

    rows = []
    for lo, hi in BANDS:
        pool = [(q, v) for q, v in cand.items() if lo <= v["t1"] < hi]
        for q, v in sorted(spread_pick(pool, a.per_band, rnd), key=lambda x: x[1]["t1"]):
            rows.append(dict(kind="sqlstorm", band=f"{lo:g}-{hi:g} s", query=q,
                             t1_s=f"{v['t1']:.3f}", e1_j=f"{v['e1']:.2f}", workers=v["workers"]))
    for p in sorted(glob.glob("compare/probes/*.sql")):
        rows.append(dict(kind="probe", band="probe", query=p, t1_s="", e1_j="", workers=""))

    os.makedirs(OUT, exist_ok=True)
    with open(f"{OUT}/manifest.csv", "w") as f:
        f.write(",".join(rows[0]) + "\n")
        f.writelines(",".join(str(v) for v in r.values()) + "\n" for r in rows)

    per_round = sum(entry_seconds(float(r["t1_s"] or PROBE_T1)) for r in rows)
    hours = a.rounds * per_round / 3600
    with open(f"{OUT}/order.txt", "w") as f:
        f.write(f"# compare set: {len(rows)} queries x {a.rounds} rounds = {len(rows) * a.rounds} entries, "
                f"seed {a.seed}\n")
        f.write(f"# estimate: ~{hours:.1f} h on a Latitude 7490 at 2.5 GHz with the 40-60 C gate\n")
        f.write("# one line per entry (run_warm_stepup.sh ORDER_FILE); '#' lines are skipped\n")
        for r in range(1, a.rounds + 1):
            order = [x["query"] for x in rows]
            rnd.shuffle(order)
            f.write(f"# round {r}\n" + "\n".join(order) + "\n")

    print(f"{'band':>10s} {'queries':>8s} {'4-worker':>9s} {'t1 range':>14s}")
    for lo, hi in BANDS:
        b = [r for r in rows if r["band"] == f"{lo:g}-{hi:g} s"]
        t = [float(r["t1_s"]) for r in b]
        print(f"{lo:g}-{hi:g} s".rjust(10), f"{len(b):8d} {sum(r['workers'] >= 4 for r in b):9d}",
              f"{min(t):6.2f}-{max(t):5.2f} s")
    print(f"{'probes':>10s} {sum(r['kind'] == 'probe' for r in rows):8d}")
    print(f"{len(rows)} queries x {a.rounds} rounds, ~{per_round / 60:.0f} min per round, ~{hours:.1f} h in all")


if __name__ == "__main__":
    main()
