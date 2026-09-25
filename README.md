# GreenSQL — PostgreSQL energy & timing benchmark harness

A self-contained harness for measuring the **wall-clock time and CPU energy
(RAPL)** of SQL queries on PostgreSQL, across several PostgreSQL major versions,
several datasets, and a matrix of server tuning parameters. The workload is
mostly TPC-H (the 53-query variant set, plus the 17k-query SQLStorm suite, and
SQLStorm's StackOverflow set),
plus a few real-world datasets.

Everything is driven through the **`Makefile`** (the single entry point), which
fills in one shared set of knobs and invokes small C "runner" programs and Bash
drivers. Results are appended to CSV files under `logs/`.

> **New here?** Read [Mental model](#mental-model), then `make help`, then
> [The Makefile](#the-makefile-command-reference).

---

## Mental model

- **Two measurement modes, and only two.**
  - **`make warm-stepup`** — the main benchmark. Every query is run `REPEATS`
    times in one saved random order; each entry gets a clean **cold start**
    (cache drop + cluster restart), `WARMUP` warm-up runs, then a measured batch
    **step-up** at `BATCH_SIZES` (N copies of the query in one `psql` process),
    warm.
  - **`make cold`** — cold-cache runs: cache drop + restart before *every*
    execution, `RUNS` executions per query, no warm-ups or batches.
  - `make run` is one plain warm pass of the same runner with no restarts — the
    quick "does this suite work" check, not a measurement protocol.
- **Runners (C, in `run/`, compiled into `bin/`)** do the measuring: run a query
  via `psql`, time it, read RAPL, sample the thermal/clock sensors, parse the
  `EXPLAIN` output, append CSV rows. Configured entirely by environment
  variables, which the Makefile sets.
- **Drivers and sweeps (Bash)**: `run/` holds the run drivers (warm step-up,
  matrix, parameter set/reset); `test/` the one-GUC parameter sweeps and the
  plan-consistency checks; `build/` the data loaders and query generators.
- **One set of knobs.** `PGVER DB_NAME DIR LOGS_DIR WARMUP BATCH_SIZES RUNS
  REPEATS WORKERS STATEMENT_TIMEOUT PGVERS DBS DRYRUN` mean the same thing for
  every target. `make help` prints them with their current values.
- **Thermal state is always logged, never forced by default.** Every batch row
  records package temperature (start/end/mean/max), hottest core, mean MHz,
  throttle counts, idle gap and power. The two protocol knobs from
  `run/thermal_runner_brief.md` — `THERMAL_EQUALISE` (temperature-gated start)
  and `FIX_CLOCK` (turbo off + performance governor) — are **off** unless set.
- **RAPL needs root + the `msr` module.** The Makefile primes `sudo`
  (`SUDO_PASSWORD`, default `a`) and loads the module.
- **PostgreSQL version == port.** Each installed major (PG15/16/17/18 by default) runs its own
  `main` cluster on its own port; `PGVER` selects the version, the port is looked
  up. Every CSV row carries `pg_version`.
- **Database naming.** `tpch` = TPC-H SF1; `tpch2`/`tpch5` = SF2/SF5;
  `<db>_idx` = indexed clone of `<db>`; `estat`, `warehouse` = real-world
  datasets; `tpch_write` = disposable scratch DB for the write benchmark.
- **Queries carry their own `EXPLAIN`.** Every `.sql` is written as
  `EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS) <statement>` so
  the runner can parse server-side figures. A bare `SELECT` runs but leaves the
  per-copy server columns empty.

---

## Quick start

```bash
# 0. Fresh Ubuntu 24.04 only: toolchain + the PostgreSQL majors (PGDG), each as
#    its own cluster. build_all.sh runs this itself, so it is optional here.
sudo bash build/bootstrap_ubuntu.sh          # PG 15 16 17 18  (or e.g. "18")

# 1. Build the runners into bin/
make

# 2. Load data: TPC-H at every scale factor on every cluster, plus the indexed
#    clones (<db>_idx). SKIP_INDEX=1 for base DBs only; SKIP_BOOTSTRAP=1 on a
#    box you already manage.
sudo bash build/build_all.sh                 # or scope: build_all.sh "1" "18"

# 3. Apply the fixed testing GUCs, run the benchmark, restore the defaults
make set-parameters
make warm-stepup DB_NAME=tpch_idx REPEATS=3
make reset-parameters

# 4. Results: logs/warm_stepup/<RUNID>/ (CSVs, run order, summary.txt)
```

Quick check that a new query suite runs at all (one warm pass, no restarts):

```bash
make fetch-sqlstorm                                   # 17k SQLStorm queries -> queries/tpch/SQLStorm
make run DIR=queries/tpch/SQLStorm DB_NAME=tpch_idx WARMUP=1 BATCH_SIZES=1 STATEMENT_TIMEOUT=10
```

SQLStorm on the StackOverflow dataset (its own database and query set):

```bash
make build-stackoverflow                              # 1 GB set -> stackoverflow_1gb + queries/stackoverflow/SQLStorm
make build-stackoverflow SO_SIZE=12gb                 # or 222gb; SO_DB=<name> to rename, FORCE=1 to rebuild
make run DIR=queries/stackoverflow/SQLStorm DB_NAME=stackoverflow_1gb WARMUP=1 BATCH_SIZES=1 STATEMENT_TIMEOUT=15
```

`build/build_stackoverflow.sh` downloads the size's archive into `Data/stackoverflow/`
(1gb 0.4 GB, 12gb 4.5 GB, 222gb 84 GB; resumable, kept for other clusters,
`KEEP_ARCHIVE=0` deletes it), loads it with `schema/stackoverflow_schema_nofk.sql`
(no foreign keys) by streaming each CSV straight into a server-side `COPY`, re-adds
the primary keys and runs `VACUUM (FREEZE, ANALYZE)`. It checks free disk first.
The 1gb set loads in under a minute to 1.2 GB. Of the 18,251 upstream queries,
5,664 are flagged invalid by upstream (`invalid_queries.csv`) and 793 more are
valid only without PostgreSQL agreeing, so 11,794 are fetched; the per-file
decision is in `queries/stackoverflow/SQLStorm.selection.csv`
(`SQLSTORM_QUERY_SET=valid|all` to widen it).

---

## PostgreSQL versions

- **Majors:** 15, 16, 17 and 18 (`PGVERS` in the Makefile, `bootstrap_ubuntu.sh`,
  `build_all.sh`, `build_tpch_indexed.sh`). PG14 leaves community support in
  November 2026 and is no longer built. `PGVER` (the version a single run
  targets) defaults to 18.
- **Minors are pinned.** `build/bootstrap_ubuntu.sh` installs each major at the
  exact minor in its `PIN_MINOR` table (15.19, 16.15, 17.11, 18.6, the newest
  PGDG releases on 2026-09-18) and writes `/etc/apt/preferences.d/greensql-postgresql`
  with priority 1001, so `apt-get upgrade` stays on that minor even after a newer
  one is published. Every box built from this repo therefore runs the same
  binaries. To move to a newer minor, bump `PIN_MINOR` and re-run the bootstrap;
  a box already on a different minor is left alone with a warning unless
  `FORCE_MINOR=1` is set (`PIN_MINOR=0` disables pinning altogether). Bumping
  a pin is a change in the thing being measured: note it next to the results.

## Installation debugging

Common problems bringing the harness up on a new box, and how to fix them.

### PostgreSQL is already installed in a way the scripts don't expect
The scripts assume the **Debian/Ubuntu packaged** PostgreSQL (`postgresql-common`):
clusters named `<ver> main`, discovered with `pg_lsclusters`; one `psql` that
selects a server by **port**; data under `/var/lib/postgresql/<ver>/main`. A
**from-source** install (e.g. into `/usr/local/pgsql`) provides none of that, so
every script fails at the port lookup ("No 'main' cluster …") or can't find
`pg_lsclusters` at all.
- **Tell which you have:** `command -v pg_lsclusters` — present ⇒ packaged; if it's
  missing but `psql` works, you have a non-packaged/source install.
- **Fix (data is disposable):** remove the old install and re-provision:
  ```bash
  sudo systemctl stop postgresql 2>/dev/null; sudo apt-get purge -y 'postgresql*'
  sudo rm -rf /var/lib/postgresql /etc/postgresql /etc/postgresql-common
  sudo bash build/bootstrap_ubuntu.sh 15 16 17 18
  ```
- A pre-existing packaged cluster (e.g. Ubuntu's default PG16) is fine — bootstrap
  adds the PGDG repo and the other majors alongside it.

### "No 'main' cluster for PostgreSQL `<N>`"
That major isn't installed, or `PGVER`/`PGVERS` names one that isn't. List what's
there with `make pg-info`; provision the missing major with
`sudo bash build/bootstrap_ubuntu.sh <N>`, or pass a version that exists.

### Only one cluster after installing several majors
Installing `postgresql-15/16/17/18` in one `apt` run sometimes auto-creates a `main`
cluster for only one version. `bootstrap_ubuntu.sh` creates the rest; by hand
it's `sudo pg_createcluster <ver> main --start`.

### "Permission denied" reading a schema .sql
`psql -f` opens the file as the **postgres** user, which can't traverse a `0750`
home dir. `build_tpch.sh` and `build_tpch_indexed.sh` stream the schema on stdin
to avoid this; if you still see it, `sudo chmod o+x /home/<user>`.

### A database looks too small / `lineitem` is empty
A COPY failed silently in an older build. `build_tpch.sh` now verifies row counts
and aborts on a short load. To repair, force a rebuild (existing DBs are skipped
otherwise):
```bash
sudo FORCE=1 SKIP_BOOTSTRAP=1 bash build/build_all.sh "1" "<ver>"
sudo bash build/build_tpch.sh <sf> <db> <ver>       # always drops + recreates
```

### dbgen won't build (no gcc/make/git)
`bootstrap_ubuntu.sh` and `build_tpch.sh` auto-install `build-essential` + `git`
as root; otherwise `sudo apt install -y build-essential git`.

### `make run` fails with a RAPL / `msr` error
The runners need Intel RAPL MSRs and the `msr` module (`sudo modprobe msr`; the
Makefile attempts this). On VMs and non-Intel CPUs the MSRs are unavailable —
data loading, `make plans` and `make outputs` still work.

### `sudo` keeps prompting / "sudo authentication failed"
The Makefile primes sudo with `SUDO_PASSWORD` (default `a`):
`make warm-stepup SUDO_PASSWORD=yourpw`.

### Low-memory box
The testing GUCs (`SHARED_BUFFERS=4GB`, `EFFECTIVE_CACHE_SIZE=12GB`) are large; on
a small machine lower them on the command line (`make test-work-mem
SHARED_BUFFERS=2GB`) or in `run/set_test_parameters.sh`.

### A CSV refuses to append ("header does not match")
The column layout changed (e.g. the thermal columns added on 2026-09-18). The
runner refuses rather than mix layouts in one file. Move the old file aside or
use another `LOGS_DIR`.

---

## Repository layout

```
Makefile          the entry point (make help)
bin/              compiled runners (git-ignored; `make` builds them)
run/              runners (.c) + run drivers (.sh)
test/             parameter sweeps + plan-consistency checks (.sh)
build/            data loaders, provisioning, query generators/fetchers
queries/          ALL SQL (see below)
schema/           DDL: tpch, index suite, estat, warehouse, stackoverflow (no-FK)
logs/             results (CSV); sub-folders per sweep / per warm-stepup run
plans/ outputs/   EXPLAIN plans / result rows from plan_builder / output_runner
Data/             raw real-world data + normalisers for estat / warehouse
archive/ matrix_logs/ old/ tpch-dbgen/   run artifacts, prior project, upstream dbgen (ignore)
```

### `run/` — runners (C) and run drivers (Bash)

| File | What it does |
|---|---|
| **`query_runner.c`** | The **warm** runner. Per query: optional thermal equalisation, `WARMUP` single-copy warm-ups, then `RUNS` measured batches at each size in `BATCH_SIZES`. Times each batch, reads RAPL, samples package/core temperature, MHz and throttle counters in a background thread, parses each copy's `EXPLAIN`. Accepts a directory or a single `.sql`. Writes `query_timing_`, `query_samples_`, `query_catalog_<db>.csv`. |
| **`cold_runner.c`** | The **cold-cache** runner: before every execution it drops the OS page cache and restarts the cluster (`pg_ctlcluster <PGVER> main restart`). Refuses to restart a cluster a live runner is using. Writes `query_cold_<db>.csv`. **All cold runs go through `make cold`.** |
| **`plan_builder.c`** | Saves each query's `EXPLAIN ANALYZE` plan to `plans/<db>/…`. `APPEND=1` appends a dated snapshot section instead of replacing, and reports whether the plan **shape** changed vs the previous snapshot (consistency testing). |
| **`output_runner.c`** | Saves each query's result rows to `outputs/<db>/…` (strips a leading `EXPLAIN`). Correctness companion to `plan_builder`. |
| **`write_runner.c`** | The **cold write** runner for mutating SQL (`queries/write/`), only against a scratch `*_write` DB. Per execution: run the file's SETUP (above `@MEASURE`), quiesce (autovacuum off on `w_*`, `CHECKPOINT`), drop caches + restart the cluster, then time only the `@MEASURE` section (RAPL, psql `\timing`, WAL bytes). No warm-up, no batching: a write cannot be repeated warm without drifting. Writes `write_cold_<db>.csv`. |
| **`rapl.c` / `rapl.h`** | Intel RAPL MSR reader (package / core / gpu / dram joules). |
| **`run_warm_stepup.sh`** | **The main benchmark driver** (`make warm-stepup`). Builds and saves the random order (with per-entry `run_id`s and each group's predecessor), does the per-entry cold start, invokes `query_runner` on one file at a time, writes `summary.txt` with every parameter plus clock/RAPL-limit state. Handles `FIX_CLOCK`. |
| **`run_matrix.sh`** | `warm-stepup` across `PGVERS × DBS`, unattended and resumable (`make matrix` / `make matrix-plan`). Each combination is one warm-stepup run folder under `logs/matrix/`. |
| **`run_equivalent.sh`** | One overnight sequence over `queries/equivalent/tpch`: plan snapshots, cold runs, warm matrix. |
| **`clock_control.sh`** | `apply` / `restore` / `status` / `with <cmd>`: disable turbo + performance governor, and put it back. Used by `FIX_CLOCK=1`. |
| **`set_test_parameters.sh`** / **`reset_all_parameters.sh`** | Apply / undo the fixed testing GUCs (`make set-parameters` / `make reset-parameters`). Reset works even when the server is down. |
| **`archive_partial.sh`** | Move a query's / a run's rows out of the live CSVs into `archive/partial/` (reversible). `make partial-archive`. |
| **`post_to_sigless.sh`** | Start/stop markers to an external power meter (optional, `SIGLESS_ADDR`). |
| **`thermal_runner_brief.md`** | The analysis brief behind the thermal columns and protocol knobs. |

### `test/` — parameter sweeps and consistency checks

`test_<param>.sh` sweeps **one** GUC (values listed in the script) with the
other testing knobs pinned (`SHARED_BUFFERS`, `EFFECTIVE_CACHE_SIZE`, `WORK_MEM`,
`MAX_PARALLEL_WORKERS_PER_GATHER`), running `make run` (warm) or `make cold`
at each value into `logs/<param>/<tag>/`, and resets everything on exit.
Invoke as `make test-<param>` (dashes for underscores):
`test-shared-buffer`, `test-work-mem`, `test-effective-cache-size`,
`test-max-parallel-workers-per-gather`, `test-hash-mem-multiplier`,
`test-parallel-leader-participation`, `test-effective-io-concurrency` (cold),
`test-io-combine-limit` (cold, PG18+), `test-io-method` (cold, PG18+).

| File | Purpose |
|---|---|
| **`work_mem_plans.sh`** | Plans (not timings) at each `work_mem` value → `plans/work_mem/wm_<size>/<db>/`. `make plans-work-mem`. |
| **`plan_snapshots.sh`** | `make plans APPEND=1` `REPEATS` times per `PGVERS × DBS`, then a drift summary of every query whose plan shape changed. `make plan-snapshots`. |
| **`planner_consistency.sh`** / **`run_planner_matrix.sh`** | Standalone cold/warm planner-drift runs with plan hashes and RAPL deltas, and their version × DB sweep. `make planner-consistency`. |

### `build/` — provisioning, data, queries

| File | Purpose |
|---|---|
| **`bootstrap_ubuntu.sh`** | Fresh Ubuntu 24.04: toolchain + PGDG repo + the requested majors, each as a `main` cluster. |
| **`build_all.sh`** | The whole data matrix: every scale factor on every cluster, plus the `_idx` clones. Resumable. |
| **`build_tpch.sh`** / **`build_tpch_indexed.sh`** | One TPC-H DB at a scale factor / its indexed clone (`ixtest_` suite). `SKEW=<z>` builds it from Microsoft Research's Zipfian generator (fetched into `tpch-dbgen-skew/`), e.g. `SKEW=0` + `SKEW=2` for a comparable uniform/skewed pair. |
| **`build_estat.sh`** / **`build_warehouse.sh`** | Load the Eurostat and warehouse datasets from `Data/`. |
| **`fetch_sqlstorm_queries.sh`** | Download a SQLStorm query set into `queries/<dataset>/SQLStorm/`, adding the `EXPLAIN` wrapper: TPC-H (~17k files, default) or `SQLSTORM_DATASET=stackoverflow` (valid queries only). `make fetch-sqlstorm`. |
| **`build_stackoverflow.sh`** | Download and load the SQLStorm StackOverflow database (1gb default, 12gb, 222gb) with the no-FK schema, and fetch its queries. `make build-stackoverflow`. |
| **`generate_tpch_query_set.py`** | Regenerate `queries/tpch/tpch-queries/` (the 53 variants; slow ones to `queries/slow/`). |
| **`generate_tpch_core_queries.py`** / **`generate_tpch_function_queries.py`** | Regenerate `queries/tpch/Core/` and `queries/tpch/Functions/`. |
| **`generate_tpch_write_queries.py`** | Regenerate `queries/write/tpch/`. |

### `queries/` — all SQL

| Path | Contents |
|---|---|
| `queries/tpch/tpch-queries/` | The TPC-H set: `q01`–`q22` folders (`q20` absent) with variants (`base.sql`, `v1_materialized.sql`, …) — 53 files, the default `DIR`. |
| `queries/tpch/SQLStorm/` | The SQLStorm suite (17k files), fetched on demand, git-ignored. |
| `queries/stackoverflow/SQLStorm/` | SQLStorm's StackOverflow queries (11,794 valid on PostgreSQL), fetched on demand, git-ignored. |
| `queries/tpch/Core/`, `queries/tpch/Functions/` | Generated operator / function micro-benchmarks. |
| `queries/estat/`, `queries/warehouse/` | The real-world datasets' queries. |
| `queries/equivalent/tpch/`, `queries/equivalent/estat/` | Sets of queries that return the **same result** written different ways (plan-consistency / equivalence tests). |
| `queries/slow/tpch/` | Deliberately slow queries kept out of the default sets. |
| `queries/write/tpch/` | Mutating SQL for `write_runner` (`@MEASURE` split). Never point `make run` at it. |

---

## The Makefile (command reference)

`make` builds the runners; `make help` lists everything with current values.

| Target | What it does |
|---|---|
| `make warm-stepup` | **The main benchmark.** `logs/warm_stepup/<RUNID>/`. Knobs: `DB_NAME DIR REPEATS WARMUP BATCH_SIZES RUNS STATEMENT_TIMEOUT RUNID ORDER_FILE THERMAL_EQUALISE FIX_CLOCK BATCH_CAP_SLOW`. |
| `make cold` | Cold-cache runs (`RUNS` per query). `logs/query_cold_<db>.csv`. |
| `make run` | One plain warm pass (`WARMUP`, `BATCH_SIZES`, `RUNS`); no restarts. |
| `make matrix` / `matrix-plan` | `warm-stepup` over `PGVERS × DBS` (resumable) / schedule + ETA only. |
| `make set-parameters` / `reset-parameters` | Apply / undo the fixed testing GUCs on `SET_VERS` (default `PGVER`). |
| `make test-<param>` | One-GUC sweep (see `test/`). `DRYRUN=1` prints the plan. |
| `make plans` / `outputs` | Save plans / result rows. `APPEND=1` for plan snapshots. |
| `make plan-snapshots` / `planner-consistency` | Plan-consistency checks. |
| `make write` / `write-db` | Cold write benchmark (restart before every execution) / rebuild its scratch DB. |
| `make index-build` / `index-verify` / `index-drop-db` | The `<db>_idx` clones. |
| `make partial-archive` | Pull rows out of the live CSVs (`QUERY=` / `RUNID=`). |
| `make fetch-sqlstorm` | Download a SQLStorm query set (`SQLSTORM_DATASET=tpch\|stackoverflow`). |
| `make build-stackoverflow` | Download + load the StackOverflow DB and fetch its queries (`SO_SIZE=1gb\|12gb\|222gb`, `SO_DB=`, `FORCE=1`). |
| `make pg-info` / `check-pg` | Clusters / verify `PGVER` resolves to a port. |

Shared knobs (defaults): `PGVER=18 DB_NAME=tpch DIR=queries/tpch/tpch-queries
LOGS_DIR=logs WARMUP=2 BATCH_SIZES="1 16" RUNS=1 REPEATS=1 WORKERS=
STATEMENT_TIMEOUT=900 PGVERS="15 16 17 18" DBS="tpch tpch_idx" DRYRUN=`.
Thermal (off by default): `THERMAL_EQUALISE=0|1|burn T_LO=55 T_HI=60
PREHEAT_MAX_S=60 COOLDOWN_MAX_S=120 PREHEAT_S=30 FIX_CLOCK=0
BATCH_CAP_SLOW= SLOW_COPY_SEC=1`.

---

## Output CSVs

Written under `LOGS_DIR` (default `logs/`; warm-stepup uses its own run folder),
one set per database (`…_<db>.csv`). Every row carries `run_id` and
`pg_version`. A runner **refuses to append** to a file whose header differs
from what it writes.

- **`query_timing_<db>.csv`** — one row per **batch**:
  `timestamp_utc, run_id, pg_version, query, phase, batch_index, batchnum, runs,
  warmup, elapsed_sec, avg_copy_elapsed_sec, server_sum_ms, client_overhead_sec,
  client_user_cpu_sec, client_sys_cpu_sec, client_max_rss_kb, failed,
  rapl_pkg_j, rapl_core_j, rapl_gpu_j, rapl_dram_j,`
  `pkg_temp_start_c, pkg_temp_end_c, pkg_temp_mean_c, pkg_temp_max_c,
  core_temp_max_c, mhz_mean, throttle_core_delta, throttle_pkg_delta,
  idle_before_s, preheat_s, cooldown_wait_s, pkg_watts_mean`.
  `phase` is `warmup`/`measured`; `batchnum` is the batch size N;
  `timestamp_utc` is taken at batch **end**. The thermal block: package
  temperature at start (the key state variable) and end, its mean/max sampled
  every 200 ms during the batch, the hottest core, mean `scaling_cur_freq` over
  all CPUs and samples, throttle-counter deltas (non-zero = hard throttling),
  wall time since the previous batch ended, the seconds the equalisation step
  took before this query's first batch (0 when off), and `rapl_pkg_j /
  elapsed_sec`.
- **`query_samples_<db>.csv`** — one row per **copy** within a batch: planning /
  execution ms, plan shape (`plan_nodes, scan_nodes, rows_out, rows_processed,
  rows_estimated, bytes_processed, rows_removed_filter, workers_launched,
  relations`), buffers, `failed`, then `pkg_temp_start_c, mhz_mean` repeated
  from the batch. Join to the batch row on `run_id + query + phase +
  batch_index`. Populated only for queries written as `EXPLAIN (ANALYZE, …)`.
- **`query_catalog_<db>.csv`** — relation sizes, once per runner invocation
  (once per warm-stepup run).
- **`query_cold_<db>.csv`** — cold-runner rows (`make cold`).
- **`write_cold_<db>.csv`** — `make write` (one row per cold execution: `setup_sec`, `elapsed_sec`, `stmt_ms`, `wal_bytes`, `failed_stage`, RAPL).

---

## The warm step-up run in detail

```bash
make set-parameters                       # shared_buffers=4GB, work_mem=64MB, effective_cache_size=12GB,
                                          # effective_io_concurrency=64, max_parallel_workers_per_gather=4,
                                          # io_combine_limit=1MB (+io_max_combine_limit) on PG18
make warm-stepup DB_NAME=tpch_idx REPEATS=3
make warm-stepup DRYRUN=1                 # just generate + save the order
make warm-stepup ORDER_FILE=logs/warm_stepup/<RUNID>/run_order_<RUNID>.txt   # replay
make reset-parameters
```

For each of the `queries × REPEATS` entries, in the saved random order:
1. drop the OS page cache and restart the cluster (clean cold start);
2. *(only if `THERMAL_EQUALISE` is set)* equalise the die temperature —
   pre-heat with an all-core burn below `T_LO`, wait above `T_HI`;
3. `WARMUP` warm-up runs (the first primes the cache);
4. `RUNS` measured batches at each `N` in `BATCH_SIZES` (default `1 16`; the
   full curve is `1 2 4 8 16` — never above 16).

Each run lives in `logs/warm_stepup/<RUNID>/`:
- `run_order_<RUNID>.txt` — the order, plus `# order: <n> <run_id> prev=<run_id>`
  lines giving every group's `run_id` and its predecessor's;
- `query_timing_<db>.csv`, `query_samples_<db>.csv`, `query_catalog_<db>.csv`;
- `console.log` — the per-entry runner output;
- `summary.txt` — total runtime, tallies, every parameter, the thermal policy,
  and the clock state (`no_turbo`, governor, min/max freq), RAPL PL1/PL2 limits
  and a `dmesg` throttle-message count.

`FIX_CLOCK=1` disables turbo and sets the performance governor for the whole
run and restores the previous values at the end (also on Ctrl-C).
`BATCH_CAP_SLOW=8` (for the 17k-query suite) skips batch sizes above 8 for any
query whose warm 1-copy run takes longer than `SLOW_COPY_SEC`.

---

## Parameter sweeps

Each `test/test_<param>.sh` isolates one server GUC: it pins the standard four
testing knobs, then steps the target GUC through its values, running the
benchmark at each into `logs/<param>/<tag>/`. Warm sweeps use `make run`
(`WARMUP`, `BATCH_SIZES`, `RUNS`); cold sweeps use `make cold` (`RUNS`).
On exit each sweep calls `run/reset_all_parameters.sh`. If one is interrupted:

```bash
make reset-parameters                                   # PGVER (default 18)
sudo bash run/reset_all_parameters.sh                   # every cluster
EXTRA_PARAMS="io_method io_workers" sudo bash run/reset_all_parameters.sh 18
```

---

## Plan consistency

```bash
make plans APPEND=1 DIR=queries/equivalent/tpch DB_NAME=tpch     # run repeatedly
make plan-snapshots PGVERS="16 18" DBS="tpch tpch_idx" REPEATS=10
```

With `APPEND=1`, `plan_builder` appends a section
`-- ==== plan_builder snapshot N <utc> pg=<ver> db=<db> query=<q> ====` plus the
plan to each `plans/<db>/<query>.txt`, and compares the new plan's *shape* (node
tree, scan/join methods, relations — cost/row/timing numbers stripped) with the
previous snapshot, printing `same shape` or `SHAPE CHANGED`. `plan-snapshots`
repeats that and summarises every query that drifted.

---

## Where to find things

| I want to… | Look at |
|---|---|
| Run the main benchmark | `make warm-stepup`; `run/run_warm_stepup.sh`; `run/query_runner.c` |
| Run cold measurements | `make cold`; `run/cold_runner.c` |
| Understand a CSV column | [Output CSVs](#output-csvs); `HDR_*` in `run/query_runner.c` |
| The thermal columns / protocol | `run/thermal_runner_brief.md`; `THERMAL_EQUALISE`, `FIX_CLOCK` in the Makefile |
| Sweep one GUC | `test/test_<param>.sh`, `make test-<param>` |
| Check the planner is stable | `make plans APPEND=1`, `make plan-snapshots` |
| Set / reset the testing GUCs | `make set-parameters` / `make reset-parameters` |
| Build or load data | `build/build_all.sh`, `build/build_tpch.sh`, `build/build_tpch_indexed.sh` |
| Regenerate or fetch queries | `build/generate_*.py`, `make fetch-sqlstorm` |
| All the commands | `make help` |
| Pull a bad measurement | `make partial-archive`, `run/archive_partial.sh` |

---

## Requirements

- **Ubuntu 24.04** (or Debian/Ubuntu with `apt`); `build/bootstrap_ubuntu.sh`
  installs everything below on a fresh box.
- PostgreSQL clusters managed via `pg_ctlcluster` / `pg_lsclusters`, one `main`
  cluster per major version, from the PGDG apt repo.
- `gcc`, `make`, `git`, TPC-H `dbgen` (fetched into `tpch-dbgen/` on demand).
- Root access (RAPL MSRs, cache drop, cluster restarts, `apt`).
- Linux with Intel RAPL and the `msr` module for the energy columns; the
  thermal columns read `coretemp` / `cpufreq` / `thermal_throttle` from sysfs
  and are simply left empty where a sensor is missing.
