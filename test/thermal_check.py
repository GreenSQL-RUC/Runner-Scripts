#!/usr/bin/env python3
"""
thermal_check.py - acceptance checks for the thermal protocol (brief section 4).

    python3 test/thermal_check.py logs/warm_stepup/<run A> [logs/warm_stepup/<run B> ...]

For each warm-stepup run folder it reads query_timing_<db>.csv and
query_samples_<db>.csv and prints, per worker class (0-2 vs 3-4 launched
workers, "4w" = exactly 4):

  temp_start_sd        SD of the package temperature at each group's first batch  (target run B: <= 2 C)
  corr(E16,t16)        batch-16 energy vs batch-16 elapsed, pooled per-query residuals  (run A strongly negative; run B within +-0.3)
  corr(E16,Tstart)     batch-16 energy residual vs package temperature at batch start   (run B near 0)
  rank(E16res,J60)     Spearman: batch-16 energy residual vs joules dissipated in the 60 s before the group  (run B ~ 0)
  rank(t16res,J60)     same for elapsed
  cv16                 median over queries of the batch-16 energy CV (sample SD) across repeats   (4w: run A ~3.4%, run B < 1.5%)
  slope_err_{1,16}R1   median |single-repeat {1,16} slope - reference slope| / reference,
                       reference = least-squares slope of E vs N over every size and repeat  (run B < 0.9%)
  throttle             sum of throttle_core_delta + throttle_pkg_delta over all batches  (must be 0)

Pooled residuals: for each query, E16 and t16 are divided by that query's mean
over its repeats, so groups of different queries can be correlated together.
With REPEATS=3 a per-query correlation has only three points, so the pooled
number is the one to read; the brief's per-query median is printed too.
Pure Python (csv + math), no numpy needed.
"""
import csv, glob, math, os, statistics, sys
from collections import defaultdict
from datetime import datetime, timezone

def fnum(x):
    try: return float(x)
    except (TypeError, ValueError): return None

def pearson(xs, ys):
    n = len(xs)
    if n < 3: return None
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs); syy = sum((y - my) ** 2 for y in ys)
    if sxx == 0 or syy == 0: return None
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / math.sqrt(sxx * syy)

def ranks(v):
    order = sorted(range(len(v)), key=lambda i: v[i]); r = [0.0] * len(v); i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and v[order[j + 1]] == v[order[i]]: j += 1
        for k in range(i, j + 1): r[order[k]] = (i + j) / 2 + 1
        i = j + 1
    return r

def spearman(xs, ys):
    return pearson(ranks(xs), ranks(ys)) if len(xs) >= 3 else None

def lsq_slope(pts):
    n = len(pts); mx = sum(p[0] for p in pts) / n; my = sum(p[1] for p in pts) / n
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    return sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx if sxx else None

def fmt(v, pct=False, nd=2):
    if v is None: return "   n/a"
    return f"{v*100:6.{nd}f}%" if pct else f"{v:6.{nd}f}"

def ts(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()

def analyse(run_dir, batch_max=16):
    timing = glob.glob(os.path.join(run_dir, "query_timing_*.csv"))
    samples = glob.glob(os.path.join(run_dir, "query_samples_*.csv"))
    if not timing: raise SystemExit(f"no query_timing_*.csv in {run_dir}")
    rows = list(csv.DictReader(open(timing[0])))
    srows = list(csv.DictReader(open(samples[0]))) if samples else []
    for r in rows:
        for k in ("elapsed_sec", "rapl_pkg_j", "pkg_temp_start_c", "idle_before_s", "preheat_s",
                  "cooldown_wait_s", "throttle_core_delta", "throttle_pkg_delta"):
            r[k] = fnum(r.get(k))
        r["batchnum"] = int(r["batchnum"]); r["t_end"] = ts(r["timestamp_utc"])
        r["t_start"] = r["t_end"] - (r["elapsed_sec"] or 0)

    # worker class per query = workers launched at the largest measured batch
    workers = {}
    for s in srows:
        if s["phase"] == "measured" and int(s["batchnum"]) == batch_max and s.get("workers_launched"):
            workers[s["query"]] = int(s["workers_launched"])
    def wclass(q):
        w = workers.get(q)
        if w is None: return "?"
        return "4w" if w >= 4 else "0-2w"

    groups = defaultdict(list)                 # run_id -> batches in time order
    for r in rows: groups[r["run_id"]].append(r)
    for g in groups.values(): g.sort(key=lambda r: r["t_end"])
    gstart = {rid: g[0]["t_start"] for rid, g in groups.items()}
    gquery = {rid: g[0]["query"] for rid, g in groups.items()}
    gtemp = {rid: g[0]["pkg_temp_start_c"] for rid, g in groups.items()}

    # joules dissipated in the window before each group's start (any query)
    def joules_before(rid, window):
        t0 = gstart[rid]
        return sum((r["rapl_pkg_j"] or 0) for r in rows if r["run_id"] != rid and t0 - window <= r["t_end"] <= t0)

    # batch-max measured rows, one per group
    b16 = {}
    for rid, g in groups.items():
        m = [r for r in g if r["phase"] == "measured" and r["batchnum"] == batch_max]
        if m and m[0]["rapl_pkg_j"] is not None and m[0]["rapl_pkg_j"] > 0: b16[rid] = m[0]
    per_query = defaultdict(list)
    for rid, r in b16.items(): per_query[r["query"]].append(rid)

    out = {}
    out["groups"] = len(groups)
    temps = [t for t in gtemp.values() if t is not None]
    out["temp_start_mean"] = statistics.mean(temps) if temps else None
    out["temp_start_sd"] = statistics.pstdev(temps) if len(temps) > 1 else None
    out["throttle"] = sum((r["throttle_core_delta"] or 0) + (r["throttle_pkg_delta"] or 0) for r in rows)
    measured = [r for r in rows if r["phase"] == "measured"]
    out["throttled_pct"] = 100.0 * sum(1 for r in measured if ((r["throttle_core_delta"] or 0) + (r["throttle_pkg_delta"] or 0)) > 0) / max(1, len(measured))
    out["hot95_pct"] = 100.0 * sum(1 for r in measured if fnum(r.get("pkg_temp_max_c")) is not None and fnum(r["pkg_temp_max_c"]) >= 95) / max(1, len(measured))
    tmax = [fnum(r.get("pkg_temp_max_c")) for r in measured]; tmax = [t for t in tmax if t is not None]
    out["tmax_median"] = statistics.median(tmax) if tmax else None
    out["preheat_mean"] = statistics.mean([g[0]["preheat_s"] or 0 for g in groups.values()])
    out["cooldown_mean"] = statistics.mean([g[0]["cooldown_wait_s"] or 0 for g in groups.values()])

    for cls in ("4w", "0-2w"):
        qs = [q for q in per_query if wclass(q) == cls]
        eres, tres, tstart, j60, j900, cvs, perq_corr = [], [], [], [], [], [], []
        for q in qs:
            rids = per_query[q]
            if len(rids) < 2: continue
            E = [b16[r]["rapl_pkg_j"] for r in rids]; T = [b16[r]["elapsed_sec"] for r in rids]
            mE, mT = statistics.mean(E), statistics.mean(T)
            cvs.append(statistics.stdev(E) / mE)      # sample SD (ddof=1), as pandas .std()
            c = pearson(E, T)
            if c is not None: perq_corr.append(c)
            for r, e, t in zip(rids, E, T):
                eres.append(e / mE - 1); tres.append(t / mT - 1)
                tstart.append(b16[r]["pkg_temp_start_c"]); j60.append(joules_before(r, 60)); j900.append(joules_before(r, 900))
        ok = [i for i, t in enumerate(tstart) if t is not None]
        out[cls] = {
            "queries": len(qs),
            "corr_E_t_pooled": pearson(eres, tres),
            "corr_E_t_perq_median": statistics.median(perq_corr) if perq_corr else None,
            "corr_E_Tstart": pearson([eres[i] for i in ok], [tstart[i] for i in ok]),
            "rank_Eres_J60": spearman(eres, j60), "rank_tres_J60": spearman(tres, j60),
            "rank_Eres_J900": spearman(eres, j900),
            "cv16_median": statistics.median(cvs) if cvs else None,
            "cv16_mean": statistics.mean(cvs) if cvs else None,
        }

    # {1,16} single-repeat slope error vs the all-sizes/all-repeats reference
    errs = defaultdict(list)
    byq = defaultdict(lambda: defaultdict(dict))   # query -> run_id -> N -> E
    for r in rows:
        if r["phase"] == "measured" and r["rapl_pkg_j"] and r["rapl_pkg_j"] > 0 and r["batchnum"] <= batch_max:
            byq[r["query"]][r["run_id"]][r["batchnum"]] = r["rapl_pkg_j"]
    for q, reps in byq.items():
        pts = [(n, e) for rep in reps.values() for n, e in rep.items()]
        ref = lsq_slope(pts)
        if not ref or ref <= 0: continue
        for rep in reps.values():
            if 1 in rep and batch_max in rep:
                s = (rep[batch_max] - rep[1]) / (batch_max - 1)
                errs[wclass(q)].append(abs(s - ref) / ref); errs["all"].append(abs(s - ref) / ref)
    out["slope_err"] = {k: statistics.median(v) for k, v in errs.items()}
    out["slope_err_mean"] = {k: statistics.mean(v) for k, v in errs.items()}
    return out

def main():
    if len(sys.argv) < 2: raise SystemExit(__doc__)
    runs = [(d.rstrip("/"), analyse(d.rstrip("/"))) for d in sys.argv[1:]]
    names = [os.path.basename(d) for d, _ in runs]
    W = 26
    print(f"{'':<{W}}" + "".join(f"{n[:22]:>24}" for n in names))
    def line(label, getter, pct=False, nd=2):
        print(f"{label:<{W}}" + "".join(f"{fmt(getter(o), pct, nd):>24}" for _, o in runs))
    line("groups", lambda o: o["groups"], nd=0)
    line("pkg_temp_start mean C", lambda o: o["temp_start_mean"], nd=1)
    line("pkg_temp_start SD C  (<=2)", lambda o: o["temp_start_sd"], nd=2)
    line("throttle deltas sum  (0)", lambda o: o["throttle"], nd=0)
    line("measured batches throttled", lambda o: o["throttled_pct"] / 100, pct=True, nd=1)
    line("measured batches >=95C", lambda o: o["hot95_pct"] / 100, pct=True, nd=1)
    line("pkg_temp_max median C", lambda o: o["tmax_median"], nd=1)
    line("preheat_s mean", lambda o: o["preheat_mean"], nd=1)
    line("cooldown_wait_s mean", lambda o: o["cooldown_mean"], nd=1)
    for cls in ("4w", "0-2w"):
        print(f"--- {cls} queries " + "-" * (W + 24 * len(runs) - 16))
        line("  queries", lambda o, c=cls: o.get(c, {}).get("queries"), nd=0)
        line("  corr(E16,t16) pooled", lambda o, c=cls: o.get(c, {}).get("corr_E_t_pooled"))
        line("  corr(E16,t16) per-q median", lambda o, c=cls: o.get(c, {}).get("corr_E_t_perq_median"))
        line("  corr(E16res,Tstart)", lambda o, c=cls: o.get(c, {}).get("corr_E_Tstart"))
        line("  rank(E16res,J60)", lambda o, c=cls: o.get(c, {}).get("rank_Eres_J60"))
        line("  rank(t16res,J60)", lambda o, c=cls: o.get(c, {}).get("rank_tres_J60"))
        line("  rank(E16res,J900)", lambda o, c=cls: o.get(c, {}).get("rank_Eres_J900"))
        line("  E16 CV median", lambda o, c=cls: o.get(c, {}).get("cv16_median"), pct=True)
        line("  E16 CV mean", lambda o, c=cls: o.get(c, {}).get("cv16_mean"), pct=True)
        line("  slope err {1,16} R1 median", lambda o, c=cls: o["slope_err"].get(c), pct=True)
    print("--- all queries " + "-" * (W + 24 * len(runs) - 16))
    line("  slope err {1,16} R1 median", lambda o: o["slope_err"].get("all"), pct=True)
    line("  slope err {1,16} R1 mean", lambda o: o["slope_err_mean"].get("all"), pct=True)

if __name__ == "__main__":
    main()
