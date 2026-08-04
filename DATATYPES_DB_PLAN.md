# Plan: a standalone `datatypes` benchmark database

**Status:** design only — no code written yet.
**Goal:** a self-contained benchmark database, completely independent of TPC-H, that
stores **every PostgreSQL 18 data type** and ships a per-type set of queries so the
harness can measure and **compare energy/runtime *between* data types**. It reuses
the existing RAPL runner unchanged for measurement; the only new runner logic is a
**guard that refuses to run a query folder against the wrong database**.

---

## 1. Why a separate database (vs. bolting types onto TPC-H)

- TPC-H is a *workload* shape (joins, aggregates over business data). Comparing raw
  per-type cost there means synthesising types from `lineitem` columns, which mixes
  the scan cost of `lineitem` into every number.
- A dedicated DB lets every type live in an **identically-shaped table** that differs
  *only* in the value column's type. Subtracting a narrow-int baseline then isolates
  exactly one variable: the data type. That is the clean "compare between datatypes"
  measurement the current suite can't give.
- It leaves TPC-H (`tpch`/`tpch2`/`tpch5`) and every already-collected result
  byte-for-byte untouched.

---

## 2. Scale-factor model

Mirror TPC-H's "~6M × SF rows" convention so the two datasets feel the same and the
existing matrix machinery (which scales its time estimate by row count) just works.

| DB name       | SF | Rows per type-table (N = 6,000,000 × SF) |
|---------------|----|------------------------------------------|
| `datatypes`   | 1  | 6,000,000                                |
| `datatypes2`  | 2  | 12,000,000                               |
| `datatypes5`  | 5  | 30,000,000                               |

Every per-type table has **the same N** within a DB, so scan cost differs only by the
type's on-disk width, not by row count. Unlike TPC-H there is **no `dbgen`** — all data
is generated in-database from `generate_series(1, N)`, which makes the build far
simpler and fully deterministic.

---

## 3. Schema design

### 3a. One narrow table per type

Each type gets a 2-column table, always the same shape:

```sql
CREATE TABLE dt_<type> (
  id  bigint,          -- = series index i; the shared narrow-int baseline column
  val <type>           -- the type under test
);
```

Rationale: a full seq-scan of `dt_json` touches **only** json data (plus the tiny
`id`), so `cost(dt_json.val) − cost(dt_integer.val)` is the pure per-type overhead.
A single wide "all types" table would drag every column's bytes through every scan
and make per-type comparison impossible, so it is explicitly rejected.

No indexes (the model is full seq-scan, matching `Functions/`). `ANALYZE` each table.

### 3b. Signature / metadata table (also the guard anchor)

```sql
CREATE TABLE datatypes_meta (
  scale_factor  int,
  row_count     bigint,
  built_at      timestamptz DEFAULT now(),
  git_note      text
);
```

`datatypes_meta` doubles as the **signature relation** the runner probes to confirm it
is really connected to a datatypes DB (see §7). TPC-H's signature is `lineitem`.

### 3c. Type inventory (from PG18 Table 8.1)

**Core (one `dt_*` table each):**

| Group        | Tables |
|--------------|--------|
| Numeric      | `dt_smallint`, `dt_integer`, `dt_bigint`, `dt_numeric`, `dt_real`, `dt_double`, `dt_money` |
| Character    | `dt_char`, `dt_varchar`, `dt_text` |
| Binary/bit   | `dt_bytea`, `dt_bit`, `dt_varbit` |
| Boolean      | `dt_boolean` |
| Date/time    | `dt_date`, `dt_time`, `dt_timetz`, `dt_timestamp`, `dt_timestamptz`, `dt_interval` |
| Network      | `dt_cidr`, `dt_inet`, `dt_macaddr`, `dt_macaddr8` |
| Geometric    | `dt_point`, `dt_line`, `dt_lseg`, `dt_box`, `dt_path`, `dt_polygon`, `dt_circle` |
| UUID/XML     | `dt_uuid`, `dt_xml` |
| JSON         | `dt_json`, `dt_jsonb` |
| Range        | `dt_int4range`, `dt_numrange`, `dt_tsrange`, `dt_daterange` (+ `dt_int4multirange`) |
| Text search  | `dt_tsvector`, `dt_tsquery` |
| Arrays       | `dt_int_array`, `dt_text_array` |
| PG-internal  | `dt_pg_lsn` |

**Edge cases — represented, with a note, not their own table:**

- `serial` / `bigserial` / `smallserial` — **not real types**; a `serial` column *is*
  `integer` + a sequence default. Represented by `dt_integer` / `dt_bigint`; the plan
  documents this rather than creating fake tables.
- `pg_snapshot` / `txid_snapshot` — storable but session/transaction-scoped; a
  full-scan energy probe is not meaningful. **Omit by default** (listed as optional).
- User-defined `enum` / composite / domain — optional single representative
  (`dt_enum`) if we want the enum category covered; off by default.

---

## 4. Data population (deterministic, from `generate_series`)

Every table is filled from the same index `i` so values are reproducible and each
type's generator is independent. Examples (full set lives in `datatypes_schema.sql`):

```sql
-- numeric family
INSERT INTO dt_integer  SELECT i, (i % 2000000000)::int          FROM generate_series(1,:N) g(i);
INSERT INTO dt_bigint   SELECT i, (i * 1000)::bigint             FROM generate_series(1,:N) g(i);
INSERT INTO dt_numeric  SELECT i, (i % 100000)::numeric(15,2)    FROM generate_series(1,:N) g(i);
INSERT INTO dt_money    SELECT i, (i % 100000)::numeric(15,2)::money FROM generate_series(1,:N) g(i);
-- temporal
INSERT INTO dt_time     SELECT i, TIME '00:00:00' + make_interval(secs => i % 86400) FROM generate_series(1,:N) g(i);
INSERT INTO dt_timestamptz SELECT i, TIMESTAMPTZ '1992-01-01+00' + make_interval(mins => i) FROM generate_series(1,:N) g(i);
-- variable-length / TOAST-able
INSERT INTO dt_text     SELECT i, md5(i::text) || ' benchmark row' FROM generate_series(1,:N) g(i);
INSERT INTO dt_bytea    SELECT i, decode(md5(i::text),'hex')       FROM generate_series(1,:N) g(i);
INSERT INTO dt_jsonb    SELECT i, jsonb_build_object('k',i,'c',md5(i::text)) FROM generate_series(1,:N) g(i);
INSERT INTO dt_tsvector SELECT i, to_tsvector('english', md5(i::text)) FROM generate_series(1,:N) g(i);
-- network / geometric / uuid
INSERT INTO dt_inet     SELECT i, ('10.0.0.0'::inet + (i % 16777216)) FROM generate_series(1,:N) g(i);
INSERT INTO dt_polygon  SELECT i, polygon(box(point(0,0), point((i%100)+1,(i%100)+1))) FROM generate_series(1,:N) g(i);
INSERT INTO dt_uuid     SELECT i, gen_random_uuid()               FROM generate_series(1,:N) g(i);
```

`:N` is substituted from the scale factor by the build script (`psql -v N=...`).

**Value-size policy (a decision, see §10):** keep values small enough to stay inline
(pure type-dispatch cost) *or* size the TOAST-able ones to force out-of-line storage
(measures detoast/I/O). This is one knob per TOAST-able type.

**Disk note:** at SF1 the TOAST-able tables (`jsonb`, `xml`, `tsvector`, `bytea`,
arrays) are each on the order of a few hundred MB; the whole DB is comparable to a
TPC-H SF1 build. It scales linearly with SF.

---

## 5. New files

| File | Purpose |
|------|---------|
| `datatypes_schema.sql` | `CREATE TABLE dt_*`, `datatypes_meta`, and the parameterised `INSERT … generate_series(1,:N)` population. Idempotent (`DROP … IF EXISTS` first). |
| `build_datatypes.sh` | `build_datatypes.sh <SF> <db_name> [pgver]` — the TPC-H-free analogue of `build_tpch.sh`: resolve the cluster port from `pg_lsclusters`, drop/create the DB, `psql -v N=$((6000000*SF)) -f datatypes_schema.sql`, `ANALYZE`, insert the `datatypes_meta` row. No `dbgen`. |
| `generate_datatypes_queries.py` | Analogue of `generate_function_queries.py`. A `SPEC` keyed **by type**; each entry lists that type's operations. Emits `SELECT <op(val)> FROM dt_<type>;` wrapped in the identical `EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)` header. |
| `datatypes_queries/` | Generated query tree (repo-root sibling of `queries/` and `slow_queries/`). |
| `datatypes_queries/.dataset` | One-line marker file containing `datatypes` — the folder→dataset binding the guard reads (§7). |
| `queries/.dataset` | One-line marker containing `tpch` — added so the existing corpus is bound to the TPC-H family too. |

### Query tree layout — organised by data type

```
datatypes_queries/
  .dataset                     # "datatypes"
  00_baseline/                 # raw one-column scans: the cross-type reference
    integer.sql  bigint.sql  numeric.sql  text.sql  bytea.sql  jsonb.sql ...
  integer/     eq.sql  add.sql  mul.sql  cast_text.sql ...
  bigint/      eq.sql  add.sql  mul.sql ...
  numeric/     eq.sql  add.sql  mul.sql  round.sql ...
  text/        eq.sql  like.sql  lower.sql  length.sql  concat.sql ...
  bytea/       eq.sql  sha256.sql  octet_length.sql ...
  jsonb/       eq.sql  arrow.sql  contains.sql  path_query.sql ...
  timestamptz/ eq.sql  extract.sql  plus_interval.sql  at_tz.sql ...
  inet/  uuid/  polygon/  daterange/  tsvector/  ...
```

Two comparison axes fall out naturally:
- **Between types:** `00_baseline/<type>.sql` scans isolate pure storage/scan cost;
  the same op name across type folders (`eq.sql`, `cast_text.sql`) compares one
  operation across types.
- **Within a type:** the op files in each `dt_<type>` folder compare that type's
  operators.

---

## 6. Makefile changes

All additive — nothing existing changes behaviour.

1. **Build target:**
   ```make
   DT_SF ?= 1
   datatypes-db: check-pg
   	@$(SUDO_PRIME) || { echo "sudo auth failed"; exit 1; }; \
   	  sudo -n bash build_datatypes.sh $(DT_SF) $(DB_NAME) $(PGVER)
   ```
   Usage: `make datatypes-db DT_SF=1 DB_NAME=datatypes PGVER=16`.

2. **Run convenience target** (sets the DIR/DB pairing so you can't fat-finger it):
   ```make
   datatypes: $(TARGET) check-pg
   	@$(MAKE) run DIR=datatypes_queries DB_NAME=$(DB_NAME)
   ```
   Default `DB_NAME` for this target documented as `datatypes`. Cold mode still works
   via `make run COLD=1 DIR=datatypes_queries DB_NAME=datatypes`.

3. **Matrix over the datatype DBs** — the matrix already accepts `DIR` and `DBS`, so:
   ```
   make matrix DIR=datatypes_queries DBS="datatypes datatypes2 datatypes5"
   ```
   works once the guard (§7) makes the DIR/DBS pairing safe. Optionally add a
   `matrix-datatypes` alias that pre-sets those two variables.

No new measurement knobs: `RUNS`/`WARMUP`/`BATCHNUM`/`WORKERS`/`PGVER` all apply
unchanged.

---

## 7. Runner changes — minimal, plus the cross-DB guard

The measurement path in `query_runner.c` / `cold_runner.c` is **dataset-agnostic**
(it runs `.sql` files under `EXPLAIN`), so **no changes to timing, RAPL, parsing, or
CSV output** are needed. The datatypes DB is measured by the existing binaries.

The one addition is a **dataset guard**, generalising the pattern that already exists
in `write_runner.c` (`PROTECTED_DBS[]` + a `REFUSING to run` exit). Today that guard is
a *negative* blocklist ("never write to tpch"); we add a *positive* match ("this
folder may only run against its declared dataset").

### 7a. Two-layer guard

**Layer 1 — folder declares its dataset.** Each query root carries a `.dataset` marker
(`datatypes` or `tpch`). At startup the runner walks up from `QUERY_DIR` to find the
nearest `.dataset` and reads the dataset name.

**Layer 2 — server must match that dataset's signature.** The runner already issues
`SHOW server_version` at connect (query_runner.c:220); alongside it, probe a signature
relation and compare to the declared dataset:

| Declared dataset | Required signature (probe) |
|------------------|----------------------------|
| `datatypes`      | `SELECT to_regclass('public.datatypes_meta')` is non-null |
| `tpch`           | `SELECT to_regclass('public.lineitem')` is non-null |

If the folder declares `datatypes` but the connected DB has no `datatypes_meta` (or
declares `tpch` but has no `lineitem`), **refuse before any measurement**, exit
non-zero, mirroring write_runner's message:

```
REFUSING to run: query folder "datatypes_queries" is bound to dataset "datatypes",
but DB_NAME="tpch" (server signature: lineitem present, datatypes_meta absent).
Point DIR and DB_NAME at the same dataset.
```

Layer 1 catches the common mistake instantly (no DB round-trip); Layer 2 catches the
subtle ones — a mistyped `DB_NAME` that happens to exist, a half-built DB, or the
right name on the wrong cluster/port.

### 7b. Where it lives

Add a small shared helper `dataset_guard.c` / `dataset_guard.h`:
```c
/* Reads QUERY_DIR/.dataset (walking up), probes the connected DB, and exits(1)
   with a REFUSING message on mismatch. Called once at startup. */
void assert_dataset_matches(const char *query_dir, const char *db_user,
                            const char *pg_port, const char *db_name);
```
Call it from `main()` in both `query_runner.c` and `cold_runner.c` right after env
parsing, before the query walk. `write_runner.c`'s existing `PROTECTED_DBS` check can
optionally be re-expressed through the same helper later, but is out of scope here.

Makefile: add `dataset_guard.c` to the `query_runner` / `cold_runner` build objects.

---

## 8. Verifying query folders can't run on the wrong database (summary)

| Failure mode | Caught by | Result |
|--------------|-----------|--------|
| `DIR=datatypes_queries DB_NAME=tpch` | Layer 1 (marker says `datatypes`, DB_NAME family ≠) + Layer 2 (`datatypes_meta` absent) | refuse, exit 1 |
| `DIR=queries DB_NAME=datatypes` | Layer 2 (`lineitem` absent) | refuse, exit 1 |
| Right name, wrong cluster/port | Layer 2 (signature absent on that server) | refuse, exit 1 |
| Half-built datatypes DB (no `datatypes_meta`) | Layer 2 | refuse, exit 1 |
| Correct pairing | both pass | run normally |

The guard runs **before** the first query and before any CSV is opened, so a
mis-pairing can never write mislabeled rows.

Optional stricter check: compare `datatypes_meta.scale_factor` to the DB-name suffix
(`datatypes5` ⇒ SF 5) and warn on mismatch — protects against loading SF1 data into a
`datatypes5`-named DB.

---

## 9. What stays unchanged

- All of TPC-H: `queries/`, `slow_queries/`, `build_tpch.sh`, `tpch_schema.sql`, and
  every collected CSV.
- Measurement internals: RAPL, slope/batch logic, warmups, `query_timing` /
  `query_samples` / `query_catalog` / `query_slope` schemas.
- `run_matrix.sh` logic (it already parameterises `DIR` and `DBS`).

---

## 10. Open decisions

1. **Type scope** — full Table 8.1 core set as listed, or also the optional edge types
   (`pg_snapshot`/`txid_snapshot`, an `enum`, multirange variants)?
2. **Value-size policy for TOAST-able types** — keep values inline (pure type cost) or
   size them to force TOAST (storage/detoast cost)? Possibly both, as a per-type knob.
3. **Table-per-type vs. a few grouped tables** — plan recommends strict one-table-per-
   type for clean isolation; confirm that's acceptable given the table count (~40).
4. **Guard strength** — is the two-layer guard (marker + signature probe) the desired
   design, or is the lightweight marker-only check enough?
5. **Matrix** — dedicated `matrix-datatypes` alias, or just document the
   `make matrix DIR=… DBS=…` invocation?

---

## 11. File-by-file change checklist (once approved)

- [ ] `datatypes_schema.sql` — new (tables + meta + parameterised population)
- [ ] `build_datatypes.sh` — new (port lookup, create DB, load, ANALYZE, meta row)
- [ ] `generate_datatypes_queries.py` — new (per-type SPEC → `datatypes_queries/`)
- [ ] `datatypes_queries/` + `datatypes_queries/.dataset` — generated
- [ ] `queries/.dataset` — new one-line marker (`tpch`)
- [ ] `dataset_guard.c` / `dataset_guard.h` — new shared guard
- [ ] `query_runner.c` / `cold_runner.c` — call `assert_dataset_matches()` at startup
- [ ] `Makefile` — `datatypes-db`, `datatypes` targets; `DT_SF`; add `dataset_guard.c`
      to the two build rules; optional `matrix-datatypes`
- [ ] (optional) `matrix-datatypes` wiring in `run_matrix.sh`
```
