# GreenSQL — PostgreSQL energy & timing benchmark harness

A self-contained harness for measuring the **wall-clock time and CPU energy
(RAPL)** of SQL queries on PostgreSQL, across several PostgreSQL major versions,
several datasets, and a matrix of server tuning parameters. The workload is
mostly TPC-H, plus a few real-world datasets.

Everything is driven through the **`Makefile`** (the single entry point) which
sets environment variables and invokes small C "runner" programs and Bash
orchestration scripts. Results are appended to CSV files under `logs/`.

> **New here / no context?** Read [Mental model](#mental-model) then
> [Where to find things](#where-to-find-things). The Makefile target table is
> the fastest index of "how do I run X".

---

## Mental model

- **Runners (C)** do the actual measuring: run a query via `psql`, time it, read
  RAPL energy counters, parse the `EXPLAIN` output, and append CSV rows. They are
  configured entirely through environment variables. See [The runners](#the-runners-c).
- **The Makefile** is how you invoke a runner: it fills in the env vars, primes
  `sudo`, loads the `msr` kernel module (for RAPL), and picks the right cluster.
- **Sweep scripts (Bash)** wrap the Makefile to vary ONE server parameter at a
  time (e.g. `shared_buffers`), writing each value's results to its own sub-folder
  of `logs/`. See [Parameter sweeps](#parameter-sweeps).
- **RAPL needs root + the `msr` module.** Nearly everything runs as root (via
  `sudo`); the Makefile handles priming (`SUDO_PASSWORD`, default `a`).
- **PostgreSQL version == port.** Each installed major (PG14/16/18 here) runs its
  own `main` cluster on its own port. `PGVER` selects the version; the port is
  looked up from it. Every CSV row carries `pg_version`, so results from
  different majors share one file and are still told apart.
- **Database naming.** `tpch` = TPC-H scale factor 1; `tpch2`/`tpch5` = SF2/SF5;
  `<db>_idx` = an indexed clone of `<db>`; `estat` and `warehouse` are real-world
  datasets; `tpch_write` is a disposable scratch DB for write tests.

---

## Quick start

```bash
# 0. Fresh Ubuntu 24.04 only: install prerequisites (toolchain + the PostgreSQL
#    majors via PGDG, each as its own cluster). build_all.sh does this for you,
#    so it is optional to run separately.
sudo bash bootstrap_ubuntu.sh          # PG 14 16 18  (or e.g. "16")

# 1. Build the runner binaries (query_runner, cold_runner, plan_builder, ...)
make all

# 2. Build/load data — generates TPC-H, loads every cluster, AND builds the
#    indexed clones (<db>_idx) too, by default (SKIP_INDEX=1 for base DBs only).
#    On a fresh box this also runs bootstrap_ubuntu.sh first (SKIP_BOOTSTRAP=1).
sudo bash build_all.sh                 # all SFs+versions; or scope: build_all.sh "1" "18"

# 3. Run the warm read benchmark on one DB/version
make run PGVER=18 DB_NAME=tpch DIR=queries/tpch/tpch-queries

# 4. Results are appended under logs/ (see “Output CSVs”)
```

A run needs root for RAPL; the Makefile primes `sudo` for you (override the
password with `make run SUDO_PASSWORD=...`).

---

## Installation debugging

Common problems bringing the harness up on a new box, and how to fix them.

### PostgreSQL is already installed in a way the scripts don't expect
The scripts assume the **Debian/Ubuntu packaged** PostgreSQL (`postgresql-common`):
clusters named `<ver> main`, discovered with `pg_lsclusters`; one `psql` that
selects a server by **port**; data under `/var/lib/postgresql/<ver>/main`. A
**from-source** install (e.g. into `/usr/local/pgsql`, as some manual guides do)
provides none of that — no `pg_lsclusters`, a bare `psql` bound to a single
hard-coded version, no `main` clusters — so every script fails at the port lookup
("No 'main' cluster …") or can't find `pg_lsclusters` at all.
- **Tell which you have:** `command -v pg_lsclusters` — present ⇒ packaged; if it's
  missing but `psql` works, you have a non-packaged/source install.
- **Fix (data is disposable):** remove the old install and re-provision the
  packaged form:
  ```bash
  sudo systemctl stop postgresql 2>/dev/null; sudo apt-get purge -y 'postgresql*'
  sudo rm -rf /var/lib/postgresql /etc/postgresql /etc/postgresql-common
  sudo bash bootstrap_ubuntu.sh 14 16 18
  ```
- A pre-existing packaged cluster (e.g. Ubuntu's default PG16) is fine — bootstrap
  adds the PGDG repo and the other majors alongside it; it won't be discovered
  wrongly, since versions are keyed by their own `main` cluster and port.

### "No 'main' cluster for PostgreSQL `<N>`"
That major isn't installed, or `PGVER`/`PGVERS` names one that isn't. List what's
there with `pg_lsclusters`; provision the missing major with
`sudo bash bootstrap_ubuntu.sh <N>`, or pass a version that exists.

### Only one cluster after installing several majors
Installing `postgresql-14/16/18` in one `apt` run sometimes auto-creates a `main`
cluster for only one version. `bootstrap_ubuntu.sh` now creates the rest; by hand
it's `sudo pg_createcluster <ver> main --start`. Ports are auto-assigned to the
next free one and discovered via `pg_lsclusters`, so the exact numbers don't matter.

### "Permission denied" reading a schema .sql
Seen as `psql: error: …/schema/….sql: Permission denied`. `psql -f` opens the file
as the **postgres** user, which can't traverse a `0750` home dir (`/home/<user>`).
`build_tpch.sh` and `build_tpch_indexed.sh` avoid this by streaming the schema on
stdin. If you still see it — from `build_estat.sh`/`build_warehouse.sh` (not yet
fixed) or an older copy — either apply the same `< "$SCHEMA"` change or
`sudo chmod o+x /home/<user>`.

### A database looks too small / `lineitem` is empty
e.g. `tpch` is ~400 MB instead of ~1.4 GB at SF1. A COPY failed, but psql's
`\copy` does **not** honor `ON_ERROR_STOP`, so an older build could finish with an
empty table and still report success. `build_tpch.sh` now verifies each table's
row count against the `.tbl` and aborts on a short load. To repair an existing
partial DB you must rebuild it — `build_all`/`build_tpch` **skip a DB that already
exists**, even a broken one, so force it:
```bash
sudo FORCE=1 SKIP_BOOTSTRAP=1 bash build_all.sh "1" "<ver>"
# or, always drops + recreates:
sudo bash build_tpch.sh <sf> <db> <ver>
```

### dbgen won't build (no gcc/make/git)
A fresh box has no toolchain. `bootstrap_ubuntu.sh` and `build_tpch.sh` auto-install
`build-essential` + `git` when run as root; offline or non-root, do it yourself:
`sudo apt install -y build-essential git`.

### `make run` fails with a RAPL / `msr` error
The energy runner needs Intel RAPL MSRs and the `msr` module (`sudo modprobe msr`;
the Makefile attempts this). On VMs, most cloud instances, or non-Intel CPUs the
MSRs are unavailable — data loading, `make plans`, and `make outputs` still work,
but the energy columns won't be populated.

### `sudo` keeps prompting / "sudo authentication failed"
The Makefile primes sudo with `SUDO_PASSWORD` (default `a`). Override it:
`make run SUDO_PASSWORD=yourpw` (same for the `test-*`/`build` targets), or run the
build scripts directly under `sudo`.

### Low-memory box
The tuning params (`shared_buffers=4GB`, `effective_cache_size=12GB`) are large; on
a small machine lower them per-sweep (e.g. `make test-work-mem WM_SHARED_BUFFERS=2GB`)
or edit `set_test_parameters.sh`. `effective_cache_size` is only a planner hint, so
it is safe to leave above physical RAM.

---

## Repository layout

### The runners (C)

Small, single-file programs. Each is configured via environment variables (the
Makefile sets them) and appends CSV rows. `make all` compiles them; the binaries
are git-ignored.

| Source | Binary | What it does |
|---|---|---|
| **`query_runner.c`** | `query_runner` | The main **warm** read benchmark. For each `.sql` file it runs `WARMUP` unmeasured executions then `RUNS` measured ones, timing each and reading RAPL energy. Uses a **batch/slope method** to remove fixed per-process overhead: it measures at two batch sizes — 1 copy and `BATCHNUM` copies concatenated into one `psql` process — and fits `E = intercept + slope·N`, so `slope` is the query's own marginal cost. Also supports a **step-up mode** (`BATCH_SIZES="1 2 4 8 16"`) that measures the whole batch-size curve, and accepts a single `.sql` file (not just a directory). Writes four CSVs (timing/samples/slope/catalog). |
| **`cold_runner.c`** | `cold_runner` | The **cold-cache** variant. Before every query it drops the OS page cache (`sync; echo 3 > /proc/sys/vm/drop_caches`) and restarts the cluster (`pg_ctlcluster <PGVER> main restart`) to empty `shared_buffers`, so reads hit disk. Refuses to restart a cluster a live sweep is using. Rows go to `query_cold_<db>.csv`. Invoked by `make cold` (or `make run COLD=1`). |
| **`plan_builder.c`** | `plan_builder` | Saves each query's **plan** (`EXPLAIN ANALYZE`) to `plans/<db>/<query>.txt`, mirroring the query folder tree. No timing/energy. `make plans`. |
| **`output_runner.c`** | `output_runner` | Saves each query's **result rows** to `outputs/<db>/<query>.txt` — strips a leading `EXPLAIN` so the underlying statement returns rows. A correctness/verification companion to `plan_builder`. `make outputs`. |
| **`write_runner.c`** | `write_runner` | Energy/timing runner for **write (mutating) SQL**. Deliberately isolated: runs ONLY against the disposable `tpch_write` DB and refuses the canonical read DBs. Each `.sql` file has a `@MEASURE`-delimited SETUP vs MEASURED section so state resets before every run. `make write`. |
| **`rapl.c` / `rapl.h`** | — | Reads Intel RAPL MSRs (package / core / gpu / dram joules). Linked into `query_runner`, `cold_runner`, and `write_runner`. Needs root and `modprobe msr`. |

### Orchestration & build scripts (Bash)

| Script | Purpose |
|---|---|
| **`bootstrap_ubuntu.sh`** | **Fresh-box provisioning (Ubuntu 24.04).** Installs the build toolchain (`build-essential`, `git`), adds the PostgreSQL PGDG apt repo, and installs the requested majors (default 14/16/18) — each `apt` install auto-creates and starts a `main` cluster. Idempotent. Both build scripts call it automatically on a fresh box. |
| **`build_all.sh`** | Build the whole data matrix: every scale factor on every installed cluster. Generates dbgen data once per SF, loads each cluster. Skips existing DBs (resumable). On a fresh box it runs `bootstrap_ubuntu.sh` first (skip with `SKIP_BOOTSTRAP=1`). |
| **`build_tpch.sh`** | Generate TPC-H data at a scale factor and load it into a fresh `<db>` on one version's cluster. Auto-installs `git`+`build-essential` if missing (for dbgen) and provisions the target version's cluster via `bootstrap_ubuntu.sh` if it doesn't exist (`SKIP_BOOTSTRAP=1` to error instead). |
| **`build_tpch_indexed.sh`** | Build indexed clones `<db>_idx` (template-clone of `<db>` + the `ixtest_` index suite from `schema/index_schema_tpch.sql`, then `ANALYZE`). Base DBs stay index-light. |
| **`build_estat.sh` / `build_warehouse.sh`** | Load the real-world Eurostat (`estat`) and retail/warehouse (`warehouse`) datasets from `Data/` into fresh DBs. |
| **`run_matrix.sh`** | Unattended sweep of the warm benchmark across versions × DB sizes; each combo is one `make run`. Resumable (`matrix_logs/completed.tsv`). `make matrix` / `make matrix-plan`. |
| **`set_test_parameters.sh`** | **Apply** the fixed testing GUCs (`shared_buffers=4GB`, `work_mem=64MB`, `effective_cache_size=12GB`, `effective_io_concurrency=64`, `max_parallel_workers_per_gather=4`, `io_combine_limit`+`io_max_combine_limit=1MB` on PG18) via `ALTER SYSTEM` + restart. `make set-parameters`. |
| **`reset_all_parameters.sh`** | **Undo** — strip GUC overrides out of `postgresql.auto.conf` and restart. Resets the core four; pass `EXTRA_PARAMS="..."` for any others. Works even when the server is down (edits the file directly). Every sweep's cleanup calls this. |
| **`run_warm_stepup.sh`** | Warm benchmark with a **per-query cold start**: runs every query `REPEATS` times in one saved **random order**; per entry it (1) drops cache + restarts, (2) does `WARMUP` runs, (3) measures a batch **step-up** `N=1,2,4,8,16`. Uses `query_runner`'s step-up + single-file modes. `make warm-stepup`. |
| **`work_mem_plans.sh`** | Sweeps `work_mem` and saves the resulting **plans** (not timings) into their own folders under `plans/work_mem/`. `make plans-work-mem`. |
| **`archive_partial.sh`** | Surgically move a query's / a run's rows out of the live CSVs into `archive/partial/` (reversible), e.g. to pull a bad measurement without re-running. Searches `logs/` recursively and mirrors sub-folder layout. `make partial-archive`. |
| **`post_to_sigless.sh`** | Post a start/stop marker to an external "sigless" power meter over HTTP (optional; enabled via `SIGLESS_ADDR`). |

### The parameter-sweep scripts (`test_*.sh`)

Each sweeps **one** server parameter while pinning the others to the standard
testing values (`shared_buffers=4GB`, `effective_cache_size=12GB`,
`work_mem=64MB`, `max_parallel_workers_per_gather=4`), writing each value's
results to its own `logs/<param>/<tag>/` sub-folder. See
[Parameter sweeps](#parameter-sweeps).

`test_shared_buffer.sh`, `test_work_mem.sh`, `test_effective_cache_size.sh`,
`test_max_parallel_workers_per_gather.sh`, `test_hash_mem_multiplier.sh`,
`test_parallel_leader_participation.sh`, `test_effective_io_concurrency.sh`
(cold), `test_io_combine_limit.sh` (cold, PG18+), `test_io_method.sh`
(cold, PG18+).

### Directories

| Path | Contents |
|---|---|
| **`queries/`** | The read workload (`.sql`). `queries/tpch/tpch-queries/` holds the TPC-H query folders (`q01`–`q22`, with `q20` absent — 21 folders) each with variants (`base.sql`, `v1_materialized.sql`, …) — 53 `.sql` files in total, the default step-up target. Also `queries/tpch/Core`, `queries/tpch/Functions`, `queries/estat`, `queries/warehouse`. Queries are written as `EXPLAIN (ANALYZE, …) SELECT …` so the runner can parse server-side figures. |
| **`write_queries/`** | Mutating SQL for `write_runner` (insert/update/delete/copy/ddl/merge/…), each with a `@MEASURE` split. |
| **`slow_queries/`** | A set of deliberately slow queries kept aside from the main corpus. |
| **`schema/`** | DDL: `tpch_schema.sql`, `index_schema_tpch.sql` (the `ixtest_` suite), `estat_schema.sql`, `warehouse_schema.sql`. |
| **`Data/`** | Raw real-world data + Python normalizers for `estat`/`warehouse`. |
| **`logs/`** | **All benchmark results (CSV).** Top-level files are the plain `make run`/`make cold` output; sub-folders (`shared_buffers/`, `work_mem/`, `effective_cache_size/`, `max_parallel_workers/`, `hash_mem_multiplier/`, `parallel_leader_participation/`, `effective_io_concurrency/`, `io_combine_limit/`, `io_method/`, `warm_stepup/`) hold the sweep results. |
| **`plans/`** | `EXPLAIN` plans from `plan_builder` (`plans/<db>/…`), plus `plans/work_mem/` from the work_mem plan sweep. |
| **`outputs/`** | Query result rows from `output_runner` (`outputs/<db>/…`). |
| **`matrix_logs/`** | Console logs + `completed.tsv` from `run_matrix.sh` (git-ignored). |
| **`archive/`** | Snapshots of earlier result sets and `archive/partial/` (rows pulled by `archive_partial.sh`). Git-ignored. |
| **`tpch-dbgen/`** | **External tool** (upstream TPC-H `dbgen`) used only to generate TPC-H `.tbl` data; fetched on demand by `build_tpch.sh`. Not part of this project's source; ignore it. |
| **`old/`** | Prior project kept locally for reference; **ignore.** |
| **`DATATYPES_DB_PLAN.md`** | Design note for a datatypes-focused test DB. |

---

## The Makefile (command reference)

`make` with no target builds the binaries. Common targets:

| Target | What it does |
|---|---|
| `make all` | Compile all runner binaries. |
| `make run` | Warm read benchmark (`query_runner`). Key vars: `PGVER`, `DB_NAME`, `DIR`, `RUNS`, `WARMUP`, `BATCHNUM`, `BATCH_SIZES`, `WORKERS`, `STATEMENT_TIMEOUT`, `LOGS_DIR`. |
| `make cold` | Cold-cache benchmark (`cold_runner`; drops cache + restarts per query). |
| `make plans` / `make outputs` | Save plans / result rows. |
| `make write` / `make write-db` | Write benchmark / (re)clone the `tpch_write` scratch DB. |
| `make matrix` / `make matrix-plan` | Unattended version × size sweep / print its plan. |
| `make index-build` / `index-verify` / `index-drop-db` | Manage the `_idx` indexed clones. |
| `make partial-archive` | Move selected rows into `archive/partial/` (needs `QUERY=` or `RUNID=`). |
| `make pg-info` / `make check-pg` | Show clusters / verify `PGVER` resolves to a port. |
| **Parameter sweeps** | `test-shared-buffer`, `test-work-mem`, `test-effective-cache-size`, `test-max-parallel-workers`, `test-hash-mem-multiplier`, `test-parallel-leader-participation`, `test-effective-io-concurrency`, `test-io-combine-limit`, `test-io-method`, `plans-work-mem`. |
| **This sweep** | `make set-parameters` then `make warm-stepup` (see below). |

Most targets accept `DRYRUN=1` to print the plan and change nothing, `PGVERS="14 16 18"` to pick versions, and `DIR=…` to scope the query set.

---

## Output CSVs

Written under `LOGS_DIR` (default `logs/`), one set per database
(`…_<db>.csv`). Every row carries `run_id` (one per runner invocation) and
`pg_version`.

- **`query_timing_<db>.csv`** — one row per **batch**. Columns:
  `timestamp_utc, run_id, pg_version, query, phase, batch_index, batchnum, runs,
  warmup, elapsed_sec, avg_copy_elapsed_sec, server_sum_ms, client_overhead_sec,
  client_user_cpu_sec, client_sys_cpu_sec, client_max_rss_kb, failed,
  rapl_pkg_j, rapl_core_j, rapl_gpu_j, rapl_dram_j`.
  `phase` is `warmup`/`measured`; `batchnum` is the batch size N (1, 2, 4, …).
- **`query_samples_<db>.csv`** — one row per **copy** within a batch (per-copy
  server-side plan figures). Join to the batch row on `run_id + query + phase +
  batch_index`.
- **`query_slope_<db>.csv`** — one row per **query** (only in slope mode,
  `BATCHNUM>1`): fitted slope + intercept for wall time and pkg/core energy.
- **`query_catalog_<db>.csv`** — relation sizes, snapshotted once per sweep.
- **`query_cold_<db>.csv`** — cold-runner rows (`make cold`).

---

## Parameter sweeps

Each `test_*.sh` isolates one server GUC: it pins the standard four testing knobs
(`shared_buffers=4GB`, `effective_cache_size=12GB`, `work_mem=64MB`,
`max_parallel_workers_per_gather=4`), then steps the target GUC through a list of
values, running the benchmark at each and writing to its own log sub-folder.

- **Warm sweeps** (`make run`): shared_buffers, work_mem, effective_cache_size,
  max_parallel_workers_per_gather, hash_mem_multiplier,
  parallel_leader_participation.
- **Cold sweeps** (`make cold`): effective_io_concurrency, io_combine_limit
  (PG18+), io_method (PG18+, sweeps `worker`/`io_uring`/`sync`).

Mechanics: the fixed GUCs are applied once (`ALTER SYSTEM`) with one restart
(`shared_buffers` needs it); the swept GUC then only reloads between values.
On exit each sweep calls **`reset_all_parameters.sh`** to restore defaults —
version-specific extras are passed via `EXTRA_PARAMS`. If a sweep is interrupted
and leaves non-default settings, run it by hand:

```bash
sudo bash reset_all_parameters.sh            # all clusters, core four
EXTRA_PARAMS="io_method io_workers" sudo bash reset_all_parameters.sh 18
```

---

## The full testing sweep (`set-parameters` + `warm-stepup`)

The current end-to-end run:

```bash
# 1. Apply the fixed testing parameters (PG18 by default)
make set-parameters
#    shared_buffers=4GB, work_mem=64MB, effective_cache_size=12GB,
#    effective_io_concurrency=64, max_parallel_workers_per_gather=4,
#    io_combine_limit=1MB (+ io_max_combine_limit=1MB)

# 2. Run the warm step-up benchmark
make warm-stepup                  # DB=tpch by default
make warm-stepup WSU_DB=tpch_idx  # the indexed database
make warm-stepup DRYRUN=1         # just generate + save the random order

# 3. Restore defaults when done
EXTRA_PARAMS="effective_io_concurrency io_combine_limit io_max_combine_limit" \
    sudo bash reset_all_parameters.sh 18
```

`warm-stepup` (script: `run_warm_stepup.sh`) runs every query in `WSU_DIR`
(default `queries/tpch/tpch-queries`, 53 files) `WSU_REPEATS` times (default 3)
in **one saved random order**. For each of the `queries × repeats` entries it:

1. drops the OS page cache and restarts the cluster (clean cold start),
2. does `WARMUP` (default 2) warm-up runs,
3. measures a **batch step-up** `BATCH_SIZES="1 2 4 8 16"` — N copies of the
   query in one `psql` process — warm.

**Each run is isolated by a `RUNID`** (UTC timestamp + random, overridable via
`WSU_RUNID`): everything lands in its own folder `logs/warm_stepup/<RUNID>/`, so a
new run never overwrites an earlier one. That folder holds:

- `run_order_<RUNID>.txt` — the exact random order used (with `run_id` in the header),
- `query_timing_<db>.csv`, `query_samples_<db>.csv`, `query_catalog_<db>.csv` — this run's results,
- `console.log` — the per-entry `make run` output,
- `summary.txt` — tallies and the **total runtime** of the run (also echoed at the end).

The `query` and `batchnum` columns tie every measurement back to its place in the
order. Re-run a saved order (into a fresh `RUNID` folder) with
`make warm-stepup ORDER_FILE=logs/warm_stepup/<RUNID>/run_order_<RUNID>.txt`.

---

## Where to find things

| I want to… | Look at |
|---|---|
| Run/understand the warm benchmark | `query_runner.c`, `make run` in `Makefile` |
| Run/understand the cold benchmark | `cold_runner.c`, `make cold` |
| Understand a result CSV's columns | [Output CSVs](#output-csvs); `HDR_*` in `query_runner.c` |
| See how a sweep pins/steps a GUC | any `test_*.sh` (they share one template) |
| Set / reset the testing GUCs | `set_test_parameters.sh` / `reset_all_parameters.sh` |
| The current full sweep | `run_warm_stepup.sh`, `make set-parameters` + `make warm-stepup` |
| Build or load data | `build_all.sh`, `build_tpch.sh`, `build_tpch_indexed.sh` |
| The query workload | `queries/` (TPC-H in `queries/tpch/tpch-queries`) |
| Schema / indexes | `schema/` |
| All the commands | `Makefile` (targets listed above) |
| Pull a bad measurement | `archive_partial.sh`, `make partial-archive` |

---

## Requirements

- **Ubuntu 24.04** (or Debian/Ubuntu with `apt`). On a fresh box,
  **`bootstrap_ubuntu.sh` installs everything below** (the build scripts call it
  automatically) — so the only manual prerequisite is `sudo`/root.
- PostgreSQL clusters managed via `pg_ctlcluster` / `pg_lsclusters` (Debian/Ubuntu
  packaging), one `main` cluster per major version — installed from the PGDG apt
  repo (bootstrap sets that up; Ubuntu's own repos carry only one major).
- `gcc`, `make`, `git`, and TPC-H `dbgen` (dbgen is fetched by `build_tpch.sh`
  into `tpch-dbgen/`; the toolchain is installed by bootstrap / build_tpch).
- Root access (RAPL MSRs, cache drop, cluster restarts, `apt`). The Makefile
  primes `sudo` (`SUDO_PASSWORD`, default `a`).
- Linux with Intel RAPL and the **`msr`** kernel module for the energy runner
  (`sudo modprobe msr`; the Makefile does this). Not needed just to load data.
