# Plan: an indexed-test mode for the GreenSQL harness

**Status:** architecture **B implemented** (built on PostgreSQL 18 only, to save
disk). Architecture A remains a design option; see below.
**Goal:** measure how **indexes change query energy/runtime** by running the same
corpus against a DB with an extended index set, then comparing to the default
(minimal-index) baseline. This is also what makes Q2/Q17/Q20 practical — they are
slow purely because the correlated columns are unindexed.

---

## 0. Implementation status (architecture B)

Delivered files:

| file | role |
|---|---|
| `index_schema_tpch.sql` | the extensive **26-index** `ixtest_`-prefixed suite (join keys, FK/PK, date/filter columns, 2 covering composites) |
| `build_tpch_indexed.sh` | `build_tpch_indexed.sh [databases] [pg_versions]` — loops every version×db, cloning each `<db>` via `TEMPLATE` into `<db>_idx` (base never modified), applies the suite, `ANALYZE`, prints sizes. Skips existing (`FORCE=1` rebuilds); `DRYRUN=1` shows the plan |
| `Makefile` | `index-build` (loops `DBS`), `index-verify` (list `ixtest_` on a DB), `index-drop-db` (reclaim disk) |

Built on **PG18 only** (`make index-build PGVERS=18`) — measured:

| DB | base | → indexed | index overhead | build |
|---|---|---|---|---|
| `tpch_idx`  (SF1) | 1379 MB | **2094 MB** | 715 MB  | 25s |
| `tpch2_idx` (SF2) | 2748 MB | **4174 MB** | 1427 MB | 56s |
| `tpch5_idx` (SF5) | 6857 MB | **10 GB**   | 3560 MB | 146s |

Validation: on `tpch_idx`, **Q17 base runs in 931 ms** (was >900,000 ms
un-indexed — a ~1000× speedup, via bitmap/index scans) and returns the correct
TPC-H SF1 answer `348406.05`; **Q20 base runs in 1099 ms** (was >900s).

Run the indexed corpus (no query changes — see §4):
```
make run DB_NAME=tpch_idx PGVER=18                              # main set
make run DB_NAME=tpch_idx PGVER=18 DIR=slow_queries/tpch/tpch-queries   # Q17/Q20, now fast
```
The `db` column in the CSVs (`tpch` vs `tpch_idx`) distinguishes the two states.
The base DBs are untouched, so the default baseline stays clean by construction.

---

## 1. The default index state (the baseline we compare against)

`build_tpch.sh` deliberately builds a **minimal** index set, and the schema
(`tpch_schema.sql`) declares **no primary keys**. The default state per DB is
exactly three indexes:

| index | table(column) |
|---|---|
| `idx_lineitem_order`  | `lineitem(l_orderkey)` |
| `idx_orders_cust`     | `orders(o_custkey)` |
| `idx_customer_nation` | `customer(c_nationkey)` |

Everything the indexed test creates is *in addition* to these three, and must be
removable without touching them.

---

## 2. Two architectures

### A. Create → sweep → drop (around each run)
Apply an index set, run the suite, drop it back to default.

### B. Parallel indexed databases (`tpch_idx`, `tpch2_idx`, `tpch5_idx`) — recommended
Build a second family of DBs *with* the extra indexes baked in. "Indexed test" =
run against `*_idx`; "default" = run against the base DBs.

| | A. create/drop | B. parallel `_idx` DBs |
|---|---|---|
| Default state | must be restored & verified every run | **structurally guaranteed** (base DBs never touched) |
| Teardown risk | interrupted run leaves stray indexes | none |
| Index build cost | every indexed sweep | once, at build |
| Disk | +indexes transiently | +indexes permanently |
| Baseline contamination | possible | impossible |
| Data labeling | needs a tag/log-suffix | the existing `db` column already distinguishes |

**Recommendation: B.** It makes "the baseline is clean" an invariant rather than
something to police, reuses the `db` column for labeling, and drops into the
matrix by just changing `DBS`. Keep **A** as a lightweight option for ad-hoc,
single-DB experiments where you don't want to build a whole second DB family.

---

## 3. Disk cost (architecture B) — measured, not estimated

A separate PostgreSQL database is a **full physical copy** of all table data —
there is no sharing/copy-on-write between databases. So each `_idx` DB = a
complete data copy **plus** the extra indexes.

Measured on this machine (a single `lineitem` single-column btree = **74 MB at
SF1**; sizes below are after the stray `lineitem2_unindexed` table was removed):

| | clean data | + new indexes (~) | = `_idx` DB (~) |
|---|---|---|---|
| SF1 (`tpch`)  | 1.38 GB | 0.45 GB | **1.8 GB** |
| SF2 (`tpch2`) | 2.75 GB | 0.9 GB  | **3.6 GB** |
| SF5 (`tpch5`) | 6.86 GB | 2.25 GB | **9.1 GB** |

New indexes add ~20–30% on top of a full copy (assumes the §6 index set: ~4
single-column `lineitem` indexes + 1 composite + `partsupp` + `orders`). Scaled
across the 3×3 matrix:

- **All 9 combos:** ≈ **+46 GB** (current ~36 GB → ~82 GB).
- You rarely need all 9: **PG16 only** ≈ +15 GB; **SF1-only, all versions** ≈ +5.4 GB.

**Build method matters:** `CREATE DATABASE tpch_idx TEMPLATE tpch` is a fast
physical clone but copies *everything* in the source; a fresh `build_tpch.sh` run
+ `index_schema` is clean but re-runs the load. Prefer the fresh build for a
pristine indexed DB.

---

## 4. Do the queries need to change? No.

Indexes are **transparent to SQL** — a query never names an index; the planner
uses them automatically when they help. The `_idx` DB has the **identical
schema** (same table/column names), so the exact same `.sql` corpus runs against
it unchanged. You select the indexed DB purely with `DB_NAME=tpch_idx` (which is
just which database psql connects to), and the existing `pg_version`-style `db`
column in the CSVs already tells indexed rows from default ones.

**One invocation nuance** (not a query change): on the indexed DB, Q17/Q20 become
fast, so an indexed sweep points `DIR` at *both* `queries/tpch/tpch-queries` and
`slow_queries/tpch/tpch-queries` to cover all 22 — same files, just also
including the ones parked in `slow_queries` for the un-indexed case.

---

## 5. `index_schema.sql` — per **dataset**, not per database

`tpch`/`tpch2`/`tpch5` share one schema, so **one file per dataset**
(`index_schema_tpch.sql`) suffices; a future `datatypes` dataset gets its own.
Per-*database* files only earn their keep for SF-specific tuning (e.g. BRIN only
at SF5) — support that as an **optional override** (`index_schema_tpch5.sql`
wins over `index_schema_tpch.sql` when present), defaulting to per-dataset.

**Naming convention is the safety mechanism.** Every test index carries a
reserved `ixtest_` prefix so teardown/verification target them precisely and
never touch the three defaults:

```sql
-- index_schema_tpch.sql
CREATE INDEX IF NOT EXISTS ixtest_lineitem_partkey  ON lineitem(l_partkey);
CREATE INDEX IF NOT EXISTS ixtest_lineitem_suppkey  ON lineitem(l_suppkey);
CREATE INDEX IF NOT EXISTS ixtest_lineitem_ps       ON lineitem(l_partkey, l_suppkey);  -- Q20
CREATE INDEX IF NOT EXISTS ixtest_lineitem_shipdate ON lineitem(l_shipdate);            -- Q1/Q6/Q14
CREATE INDEX IF NOT EXISTS ixtest_partsupp_partkey  ON partsupp(ps_partkey);            -- Q2/Q17
CREATE INDEX IF NOT EXISTS ixtest_orders_orderdate  ON orders(o_orderdate);             -- Q3/Q4/Q5
-- ... extend with the rest of the TPC-H FK/date indexes you want to test
```

Teardown is then content-free and robust:

```sql
SELECT 'DROP INDEX IF EXISTS '||indexname||';'
FROM pg_indexes WHERE indexname LIKE 'ixtest_%';
```

`ANALYZE` runs after both apply and clear — stats must match the index state, and
it is outside the measurement window (same principle as dbgen generation and
`cold_runner`'s cache drop being pre-measurement).

---

## 6. Makefile integration

New targets, all resolving `DB_NAME` + `PGVER→PGPORT` exactly like `run`/`cold`
(so they are per-database automatically):

```make
INDEX_SCHEMA ?= index_schema_$(DATASET).sql   # per-DB override checked first
index-apply:  check-pg   # create the ixtest_ indexes on DB_NAME, then ANALYZE
index-clear:  check-pg   # drop every ixtest_* on DB_NAME, then ANALYZE
index-verify: check-pg   # assert live index set == default manifest (else fail)
index-test:   check-pg   # apply -> run suite -> clear, teardown guaranteed
```

`index-test` must clean up **even on Ctrl-C/error**, which a plain make recipe
can't — so it delegates to a wrapper `run_indexed.sh` built around a `trap`:

```bash
apply_indexes "$DB" "$PORT"
trap 'clear_indexes "$DB" "$PORT"' EXIT INT TERM    # runs no matter how we leave
INDEX_SET=ixtest sudo -n env $(RUN_ENV) ./query_runner
```

(Architecture B needs none of this — the `_idx` DBs are built once; an indexed
run is just `make run DB_NAME=tpch_idx DIR=...`.)

---

## 7. How normal runs verify the default (clean) state

A normal sweep's baseline is only valid if no `ixtest_*` index leaked from an
interrupted `index-test`. Two complementary layers (mirroring `check-pg` and the
dataset/cold guards):

- **Manifest + check.** A per-dataset `default_indexes_tpch.txt` lists the
  expected indexes (the three from `build_tpch.sh`). `index-verify` diffs
  `pg_indexes` against it; **`run` gains it as a prerequisite** (like `check-pg`),
  so a normal sweep *refuses to start* if the live DB has any index not in the
  manifest.
- **Runner-level guard (optional, catches direct `./query_runner`).** At startup
  the runner probes `SELECT count(*) FROM pg_indexes WHERE indexname LIKE
  'ixtest_%'`; if >0 and `INDEX_SET` is unset, it refuses with a REFUSING message
  — the same shape as `write_runner`'s `PROTECTED_DBS` refusal.

**`INDEX_SET` does double duty:** it is the signal that "extra indexes are
intentional here" (bypasses the clean-default assertion) *and* the data label. A
normal run leaves it empty → asserts clean; an indexed run sets it → skips the
assert. Under architecture B this keys off the DB name instead (base DBs must be
clean; `_idx` DBs are expected dirty).

---

## 8. Keeping indexed vs. default data distinguishable

1. **Separate log file** — `logs/query_timing_<db>_ixtest.csv` via the existing
   `LOG_FILE`/`LOGS_DIR` overrides (zero code change). Simple; analysis joins two
   files.
2. **Label column (cleaner)** — add an `index_set` column (default `""`, else
   `INDEX_SET`) to the CSV schemas so one file self-identifies. Same shape as the
   `pg_version` column; touches headers + parsers.
3. **Architecture B** — the existing `db` column already distinguishes `tpch`
   vs `tpch_idx`, so **no new field is needed**. Another point in B's favor.

---

## 9. Matrix

`run_matrix.sh` gains an `INDEXED=1` mode (or a `matrix-indexed` alias) that, per
`(version, db)` combo, does apply → sweep → clear (arch A), or simply sweeps the
`_idx` DB list `DBS="tpch_idx tpch2_idx tpch5_idx"` (arch B — no new logic). The
DIR-aware time estimate already scales; for arch A add the one-time index-build
cost per combo.

---

## 10. Other options worth considering

- **Per-query index sets** — create only the index(es) relevant to the query
  under test, measuring a single index's *marginal* energy effect. Most
  scientific, most complex (couples the runner to a per-query index manifest).
- **Index-type sweep** — btree vs hash vs BRIN (BRIN on `l_shipdate` is tiny and
  interesting for a scan-heavy energy study).
- **Covering indexes** — force *index-only scans* and measure their energy vs
  heap fetches.
- **CLUSTER / partitioning** — physical-layout levers; bigger build cost,
  separate experiment.
- **Materialized views** — precomputed aggregates as an alternative lever.

---

## 11. Recommendation summary

- Primary path: **architecture B** (parallel `_idx` DBs) — clean baseline
  invariant, `db`-column labeling, trivial matrix wiring.
- Keep **create/drop `index-test`** (architecture A, `trap`-guarded, `ixtest_`
  prefix) for ad-hoc single-DB experiments.
- **One `index_schema_<dataset>.sql`** with optional per-DB override.
- Gate normal runs on an index manifest keyed by the `INDEX_SET` signal.
- No corpus queries change; indexed runs also include `slow_queries/tpch/tpch-queries`.
```
