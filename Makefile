# ===== query_runner Makefile =====
#
# Build:
#   make
#
# Run all queries under ./queries:
#   make run
#
# Run only the queries in a sub-folder (recursively):
#   make run DIR=queries/tpch/Core
#
# Cap parallel workers for the WHOLE sweep (applied to every query via
# PGOPTIONS; leave unset to let the planner decide, WORKERS=0 for fully serial):
#   make run WORKERS=2
#
# Slope mode (BATCHNUM>1): fit E=intercept+slope*N through two points, N=1 and
# N=BATCHNUM. slope = the query's overhead-free marginal energy/time; intercept
# = the fixed per-process cost. The N=1 point is NOT a separate phase - it is
# the WARM warmups (a warm 1-copy warmup equals a dedicated 1-copy run). RUNS =
# batches at N=BATCHNUM; WARMUP = single-copy warmups first (#1 primes the cache,
# warm ones anchor N=1, so WARMUP>=2 gives a clean anchor). Outputs: query_timing
# (per batch), query_samples (per copy), query_slope (per query). BATCHNUM=1 is
# the classic single-size runner (no slope file).
#   make run BATCHNUM=20
#   make run BATCHNUM=20 RUNS=3 WARMUP=2
#
# Choose which PostgreSQL major to measure. Each installed version runs its own
# cluster on its own port; PGVER looks the port up and every psql call is sent
# there. Defaults to 16.
#   make run PGVER=18
#   make run PGVER=14 DB_NAME=tpch5
# Rows carry a pg_version column, so sweeps of different majors can share a log
# file and still be told apart.
#
# Reading RAPL MSRs and running psql as the postgres user both need root, so the
# run targets use sudo. Override any default on the command line, e.g.:
#   make run DIR=queries/tpch/Core RUNS=5 DB_NAME=tpch WORKERS=4
#
# WRITE benchmark (mutating SQL). Runs ONLY against a disposable scratch database
# (tpch_write), never the read corpus. One-time setup, then run:
#   make write-db        # (re)clone tpch -> tpch_write
#   make write           # measure ./write_queries against the scratch DB

CC      = gcc
CFLAGS  = -O2 -Wall -Wextra
LDFLAGS = -lm
TARGET  = query_runner
SRC     = query_runner.c rapl.c

# Runtime knobs (passed through to the program as environment variables).
# DATASET = which query corpus / schema family to run. "tpch" spans the DB_NAMEs
# tpch, tpch2, tpch5 (the scale-factor variants); a future corpus lives under
# queries/<dataset>. Every dir default below derives from it, so a whole other
# dataset runs with e.g. `make run DATASET=datatypes DB_NAME=datatypes`.
DATASET       ?= tpch
DIR           ?= queries/$(DATASET)
# All result CSVs are written under LOGS_DIR (the runners create it if missing).
LOGS_DIR      ?= logs
RUNS          ?= 1
# Unmeasured batches before the measured ones; 0 disables. Comment kept off the
# value line: GNU Make folds the whitespace before an inline "#" into the value.
WARMUP        ?= 2
# Copies of each query per batch, run in ONE psql process to amortise the ~40ms
# client overhead. BATCHNUM=1 is the classic one-process-per-query behaviour.
BATCHNUM      ?= 1
DB_NAME       ?= tpch
DB_USER       ?= postgres

# Which PostgreSQL major to talk to. Each installed version has its own cluster
# on its own port, so the port IS the version selector. pg_createcluster hands
# out ports in install order, so look it up rather than hard-coding it.
# Comments kept off the value lines: GNU Make folds the whitespace before an
# inline "#" into the value.
PGVER         ?= 16
PGPORT        ?= $(shell pg_lsclusters -h 2>/dev/null | awk -v v='$(PGVER)' '$$1 == v && $$2 == "main" { print $$3 }')
WORKERS       ?=              # max_parallel_workers_per_gather for every query; empty = planner decides
# Step-up mode: BATCH_SIZES="1 2 4 8 16" measures each query at every listed
# batch size after the warmups (whole batch-size curve, no slope). Empty = the
# usual two-point (1, BATCHNUM) slope. SKIP_CATALOG=1 skips the per-relation
# snapshot (the warm step-up driver snapshots once, not per query).
BATCH_SIZES   ?=
SKIP_CATALOG  ?=
# Seconds before the SERVER cancels a query; empty = no limit. The safety net
# for unattended sweeps - a wedged query is cancelled rather than running all
# night. Comment kept off the value line (GNU Make folds trailing whitespace).
STATEMENT_TIMEOUT ?=
LOG_FILE      ?=              # default: $(LOGS_DIR)/query_timing_<DB_NAME>.csv (one log per database)
SAMPLE_FILE   ?=              # default: $(LOGS_DIR)/query_samples_<DB_NAME>.csv (one row per individual run)
CATALOG_FILE  ?=              # default: $(LOGS_DIR)/query_catalog_<DB_NAME>.csv (relation sizes, once per sweep)
SLOPE_FILE    ?=              # default: $(LOGS_DIR)/query_slope_<DB_NAME>.csv (per-query slope, BATCHNUM>1 only)
SIGLESS_ADDR  ?=              # e.g. 127.0.0.1:8000 to enable the power meter
SIGLESS_CHANNEL ?= CH1

# Pre-authenticate sudo so the run doesn't stop to prompt for a password.
# Override on the command line if your password differs: make run SUDO_PASSWORD=...
SUDO_PASSWORD ?= a
SUDO_PRIME    = printf '%s\n' '$(SUDO_PASSWORD)' | sudo -S -v >/dev/null 2>&1

# sudo needs the 'msr' kernel module to expose /dev/cpu/*/msr for RAPL.
RUN_ENV = QUERY_DIR="$(DIR)" RUNS=$(RUNS) WARMUP="$(WARMUP)" BATCHNUM="$(BATCHNUM)" \
          BATCH_SIZES="$(BATCH_SIZES)" SKIP_CATALOG="$(SKIP_CATALOG)" \
          DB_NAME="$(DB_NAME)" DB_USER="$(DB_USER)" PGPORT="$(PGPORT)" \
          WORKERS="$(WORKERS)" STATEMENT_TIMEOUT="$(STATEMENT_TIMEOUT)" \
          LOGS_DIR="$(LOGS_DIR)" \
          LOG_FILE="$(LOG_FILE)" SAMPLE_FILE="$(SAMPLE_FILE)" CATALOG_FILE="$(CATALOG_FILE)" \
          SLOPE_FILE="$(SLOPE_FILE)" \
          SIGLESS_ADDR="$(SIGLESS_ADDR)" SIGLESS_CHANNEL="$(SIGLESS_CHANNEL)"

PLAN_TARGET = plan_builder
PLAN_ENV = QUERY_DIR="$(DIR)" PLANS_DIR="$(PLANS_DIR)" DB_NAME="$(DB_NAME)" DB_USER="$(DB_USER)" \
           WORKERS="$(WORKERS)" PGPORT="$(PGPORT)"
# plan_builder writes under $(PLANS_DIR)/<DB_NAME>/, so this is just the root -
# the per-database subfolder (tpch, tpch_idx, ...) comes from DB_NAME, which is
# what keeps tpch and tpch_idx plans from overwriting each other.
PLANS_DIR ?= plans

OUTPUT_TARGET = output_runner
OUTPUT_ENV = QUERY_DIR="$(DIR)" OUTPUTS_DIR="$(OUTPUTS_DIR)" DB_NAME="$(DB_NAME)" DB_USER="$(DB_USER)" \
             MAX_ROWS="$(MAX_ROWS)" PGPORT="$(PGPORT)"
# output_runner writes under $(OUTPUTS_DIR)/<DB_NAME>/ (per-database subfolder
# comes from DB_NAME), so this is just the root - keeps tpch vs tpch_idx apart.
OUTPUTS_DIR ?= outputs
MAX_ROWS ?= 1000

# Write benchmark (mutating SQL) - strictly isolated from the read corpus.
# NOTE: no inline comments on the value lines below - GNU Make would fold the
# whitespace before the "#" into the value (e.g. DB_NAME="tpch_write   ").
#   WRITE_DB       disposable scratch DB; never the read corpus
#   WRITE_TEMPLATE canonical DB used ONLY as a copy template for write-db
#   WRITE_RUNS     measured runs per query; state is reset before each
#   WRITE_LOG      overrides the default write_timing_<WRITE_DB>.csv
#   WRITE_SAMPLES  overrides the default write_samples_<WRITE_DB>.csv
#   WRITE_WARMUP   unmeasured runs first (setup still resets state each time)
WRITE_TARGET   = write_runner
WRITE_DIR      ?= write_queries/$(DATASET)
WRITE_DB       ?= tpch_write
WRITE_TEMPLATE ?= tpch
WRITE_RUNS     ?= 3
WRITE_WARMUP   ?= 2
WRITE_LOG      ?=
WRITE_SAMPLES  ?=
WRITE_ENV = QUERY_DIR="$(WRITE_DIR)" DB_NAME="$(WRITE_DB)" DB_USER="$(DB_USER)" \
            RUNS="$(WRITE_RUNS)" WARMUP="$(WRITE_WARMUP)" PGPORT="$(PGPORT)" \
            LOG_FILE="$(WRITE_LOG)" SAMPLE_FILE="$(WRITE_SAMPLES)" LOGS_DIR="$(LOGS_DIR)"

# COLD-cache benchmark - a SEPARATE mode (cold_runner.c). It ignores BATCHNUM and
# WARMUP: each query is run RUNS times, and before every run the OS page cache is
# dropped and the cluster is restarted (empties shared_buffers). Off by default;
# you opt in with `make cold` (or `make run COLD=1`). Rows go to query_cold_<db>.
# PGVER is needed to name the cluster for the restart. COLD_DRY=1 skips the
# cache-drop/restart (warm rows) for a safe plumbing test.
COLD_TARGET = cold_runner
COLD_LOG   ?=
COLD_DRY   ?=
COLD_ENV = QUERY_DIR="$(DIR)" DB_NAME="$(DB_NAME)" DB_USER="$(DB_USER)" \
           RUNS="$(RUNS)" PGVER="$(PGVER)" PGPORT="$(PGPORT)" \
           WORKERS="$(WORKERS)" STATEMENT_TIMEOUT="$(STATEMENT_TIMEOUT)" \
           COLD_LOG="$(COLD_LOG)" DRYRUN="$(COLD_DRY)" LOGS_DIR="$(LOGS_DIR)"

# `all` (build) is the default even though it is not the first rule in the file.
.DEFAULT_GOAL := all
.PHONY: all run cold plans outputs write write-db clean pg-info check-pg matrix matrix-plan partial-archive index-build index-verify index-drop-db test-shared-buffer test-work-mem test-effective-cache-size test-max-parallel-workers plans-work-mem test-hash-mem-multiplier test-parallel-leader-participation test-effective-io-concurrency test-io-combine-limit test-io-method set-parameters warm-stepup

# Move a query's - or a whole run's - rows out of the live result CSVs into
# archive/partial/ (e.g. to pull a bad measurement without re-running the whole
# sweep). Reversible: rows are moved, not deleted. Safe alongside the matrix -
# any CSV a running sweep has open is skipped. QUERY is a substring of the query
# column; RUNID is an exact run_id (col 2); VER/DB are optional filters (DB empty
# = every database's files). At least one of QUERY/RUNID is required; given both,
# they AND. DRYRUN=1 previews, changes nothing. LOGS_DIR is searched RECURSIVELY,
# so the sweep subfolders (logs/shared_buffers/sb_*, logs/work_mem/wm_*, ...) are
# covered by default and archived to a mirrored path under archive/partial/;
# narrow it (LOGS_DIR=logs/shared_buffers) to scope one sweep.
#   make partial-archive QUERY=scan_orders
#   make partial-archive RUNID=D989360CB80E6EEE           # every row of that run
#   make partial-archive RUNID=D989360CB80E6EEE QUERY=scan_orders
#   make partial-archive QUERY=log10_numeric VER=18 DB=tpch5
#   make partial-archive QUERY=q05 LOGS_DIR=logs/shared_buffers  # just that sweep
#   make partial-archive QUERY=scan_orders DRYRUN=1
QUERY  ?=
RUNID  ?=
VER    ?=
DB     ?=
DRYRUN ?=
partial-archive:
	@[ -n "$(QUERY)" ] || [ -n "$(RUNID)" ] || { echo "usage: make partial-archive { QUERY=<name> | RUNID=<id> } [VER=<pgver>] [DB=<dbname>] [DRYRUN=1]"; exit 1; }
	@$(SUDO_PRIME) \
	    || { echo "sudo authentication failed (override with: make partial-archive SUDO_PASSWORD=...)"; exit 1; }; \
	  sudo -n env QUERY="$(QUERY)" RUNID="$(RUNID)" VER="$(VER)" DB="$(DB)" DRYRUN="$(DRYRUN)" LOGS_DIR="$(LOGS_DIR)" bash archive_partial.sh

# Show the installed clusters and what PGVER currently resolves to.
pg-info:
	@pg_lsclusters
	@echo "PGVER=$(PGVER) -> PGPORT=$(PGPORT)"

# Fail early and loudly rather than silently falling back to psql's default
# port, which would measure the wrong server and mislabel nothing.
check-pg:
	@if [ -z "$(PGPORT)" ]; then \
	    echo "No 'main' cluster for PostgreSQL $(PGVER). Installed clusters:"; \
	    pg_lsclusters; \
	    exit 1; \
	fi

all: $(TARGET) $(PLAN_TARGET) $(OUTPUT_TARGET) $(WRITE_TARGET) $(COLD_TARGET)

$(TARGET): $(SRC) rapl.h
	$(CC) $(CFLAGS) -o $(TARGET) $(SRC) $(LDFLAGS)

# plan_builder / output_runner need no RAPL/MSR, so they have no rapl.c dependency.
$(PLAN_TARGET): $(PLAN_TARGET).c
	$(CC) $(CFLAGS) -o $(PLAN_TARGET) $(PLAN_TARGET).c

$(OUTPUT_TARGET): $(OUTPUT_TARGET).c
	$(CC) $(CFLAGS) -o $(OUTPUT_TARGET) $(OUTPUT_TARGET).c

# write_runner reads RAPL, so it links rapl.c like query_runner.
$(WRITE_TARGET): $(WRITE_TARGET).c rapl.c rapl.h
	$(CC) $(CFLAGS) -o $(WRITE_TARGET) $(WRITE_TARGET).c rapl.c $(LDFLAGS)

# cold_runner reads RAPL too, so it links rapl.c.
$(COLD_TARGET): $(COLD_TARGET).c rapl.c rapl.h
	$(CC) $(CFLAGS) -o $(COLD_TARGET) $(COLD_TARGET).c rapl.c $(LDFLAGS)

# The prime and the run must share ONE shell: sudo caches its credential per
# terminal, and make runs each recipe line in a separate shell, so a credential
# primed on its own line would not be visible to the run on the next line.
run: $(TARGET) $(COLD_TARGET) check-pg
	@mkdir -p "$(LOGS_DIR)"; \
	  $(SUDO_PRIME) \
	    || { echo "sudo authentication failed (override with: make run SUDO_PASSWORD=...)"; exit 1; }; \
	  sudo -n modprobe msr 2>/dev/null || true; \
	  if [ "$(COLD)" = "1" ]; then \
	    sudo -n env $(COLD_ENV) ./$(COLD_TARGET); \
	  else \
	    sudo -n env $(RUN_ENV) ./$(TARGET); \
	  fi

# Cold-cache mode (== make run COLD=1): each query RUNS times, OS cache dropped
# and cluster restarted before each. Needs PGVER to restart the right cluster.
#   make cold PGVER=16 DB_NAME=tpch RUNS=5 DIR=queries/tpch/Core/00_baseline
#   make cold PGVER=16 COLD_DRY=1        # warm dry run, no drop/restart (test)
cold: $(COLD_TARGET) check-pg
	@mkdir -p "$(LOGS_DIR)"; \
	  $(SUDO_PRIME) \
	    || { echo "sudo authentication failed (override with: make cold SUDO_PASSWORD=...)"; exit 1; }; \
	  sudo -n modprobe msr 2>/dev/null || true; \
	  sudo -n env $(COLD_ENV) ./$(COLD_TARGET)

# Save the query plan of every query to ./plans (single run each, no measuring).
# Runs under sudo so the inner "sudo -u postgres psql" needs no password prompt;
# plan files are chowned back to you afterwards.
plans: $(PLAN_TARGET) check-pg
	@$(SUDO_PRIME) \
	    || { echo "sudo authentication failed (override with: make plans SUDO_PASSWORD=...)"; exit 1; }; \
	  sudo -n env $(PLAN_ENV) ./$(PLAN_TARGET)

# Save each query's OUTPUT (result rows) to ./outputs. Capped to MAX_ROWS rows
# per query by default; use MAX_ROWS=0 for full (potentially huge) results.
outputs: $(OUTPUT_TARGET) check-pg
	@$(SUDO_PRIME) \
	    || { echo "sudo authentication failed (override with: make outputs SUDO_PASSWORD=...)"; exit 1; }; \
	  sudo -n env $(OUTPUT_ENV) ./$(OUTPUT_TARGET)

# Sweep every PostgreSQL version x database size, unattended (see run_matrix.sh).
# Resumable: finished combinations are skipped on a re-run. Subset with PGVERS
# and/or DBS. "matrix-plan" prints the schedule and time estimate, runs nothing.
#   make matrix-plan
#   make matrix
#   make matrix PGVERS=18
#   make matrix DBS="tpch tpch2"
#   make matrix FRESH=1              # ignore the manifest, redo everything
PGVERS ?= 14 16 18
DBS    ?= tpch tpch2 tpch5

MATRIX_ENV = PGVERS="$(PGVERS)" DBS="$(DBS)" RUNS="$(RUNS)" WARMUP="$(WARMUP)" \
             BATCHNUM="$(BATCHNUM)" DIR="$(DIR)" REFERENCE_DIR="queries/$(DATASET)" \
             WORKERS="$(WORKERS)" LOGS_DIR="$(LOGS_DIR)" \
             STATEMENT_TIMEOUT="$(STATEMENT_TIMEOUT)" FRESH="$(FRESH)"
FRESH ?= 0

matrix-plan:
	@$(SUDO_PRIME) || { echo "sudo authentication failed"; exit 1; }; \
	  sudo -n env $(MATRIX_ENV) DRYRUN=1 bash run_matrix.sh

matrix:
	@$(SUDO_PRIME) || { echo "sudo authentication failed"; exit 1; }; \
	  sudo -n modprobe msr 2>/dev/null || true; \
	  sudo -n env $(MATRIX_ENV) bash run_matrix.sh

# (Re)create the disposable scratch database as a clone of the canonical read DB.
# The read DB is used ONLY as a copy template here and is never modified. Run
# this once before "make write" (and again if you want a fresh scratch DB).
write-db: check-pg
	@$(SUDO_PRIME) \
	    || { echo "sudo authentication failed (override with: make write-db SUDO_PASSWORD=...)"; exit 1; }; \
	  sudo -n -u $(DB_USER) psql -p $(PGPORT) -d postgres -v ON_ERROR_STOP=1 -c \
	    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('$(WRITE_DB)','$(WRITE_TEMPLATE)') AND pid <> pg_backend_pid();" >/dev/null; \
	  sudo -n -u $(DB_USER) psql -p $(PGPORT) -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS $(WRITE_DB);" \
	    && sudo -n -u $(DB_USER) psql -p $(PGPORT) -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE $(WRITE_DB) TEMPLATE $(WRITE_TEMPLATE);" \
	    && echo "scratch DB '$(WRITE_DB)' (re)created from template '$(WRITE_TEMPLATE)' on PostgreSQL $(PGVER) (port $(PGPORT))"

# Measure the write corpus (./write_queries) against the scratch DB. Refuses to
# run if WRITE_DB is a canonical read database (enforced in write_runner.c).
write: $(WRITE_TARGET) check-pg
	@mkdir -p "$(LOGS_DIR)"; \
	  $(SUDO_PRIME) \
	    || { echo "sudo authentication failed (override with: make write SUDO_PASSWORD=...)"; exit 1; }; \
	  sudo -n modprobe msr 2>/dev/null || true; \
	  sudo -n env $(WRITE_ENV) ./$(WRITE_TARGET)

# ----- Indexed-test databases (architecture B of INDEXED_TEST_PLAN.md) --------
# Build <db>_idx clones for every DB in DBS across every version in PGVERS, each a
# full copy of its base DB plus the extensive ixtest_ index suite. Base DBs are
# used only as templates and never modified, so the default (minimal-index)
# baseline stays clean. Existing _idx DBs are skipped (FORCE=1 rebuilds). Run the
# indexed corpus with e.g. `make run DB_NAME=tpch_idx PGVER=18` (add a second run
# over slow_queries/tpch/tpch-queries - Q17/Q20 are fast on the indexed DB).
#   make index-build PGVERS=18                 # tpch_idx/tpch2_idx/tpch5_idx on PG18
#   make index-build                           # all versions (14 16 18) - large; see disk note
#   make index-build PGVERS="16 18" DBS=tpch    # a subset
#   make index-build DRYRUN=1                   # show the plan, build nothing
#   make index-verify DB_NAME=tpch_idx PGVER=18
#   make index-drop-db PGVER=18                # drop the _idx clones on one version
IDX_SCHEMA ?= schema/index_schema_$(DATASET).sql
index-build:
	@$(SUDO_PRIME) \
	    || { echo "sudo authentication failed (override with: make index-build SUDO_PASSWORD=...)"; exit 1; }; \
	  sudo -n env INDEX_SCHEMA="$(IDX_SCHEMA)" FORCE="$(FORCE)" DRYRUN="$(DRYRUN)" \
	    bash build_tpch_indexed.sh "$(DBS)" "$(PGVERS)"

# Show the ixtest_ indexes on DB_NAME (empty on a clean base DB; populated on _idx).
index-verify: check-pg
	@$(SUDO_PRIME) \
	    || { echo "sudo authentication failed"; exit 1; }; \
	  sudo -n -u $(DB_USER) psql -p $(PGPORT) -d $(DB_NAME) -c \
	    "SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) AS size \
	       FROM pg_stat_user_indexes WHERE indexrelname LIKE 'ixtest_%' ORDER BY 1;"

# Drop the _idx clones for every DB in DBS (reclaim disk).
index-drop-db:
	@$(SUDO_PRIME) \
	    || { echo "sudo authentication failed"; exit 1; }; \
	  for db in $(DBS); do \
	    sudo -n -u $(DB_USER) psql -p $(PGPORT) -d postgres -c "DROP DATABASE IF EXISTS $${db}_idx;"; \
	  done

# ----- shared_buffers sweep (warm-cache runs at several buffer sizes) ----------
# test_shared_buffer.sh sweeps shared_buffers (128MB default, 512MB, 1GB, 4GB,
# 8GB - the SIZES live in the script) and runs the warm-cache benchmark at each,
# on SB_DBS across PGVERS, writing each size's results to its own dir under
# SB_LOGS/sb_<size>/. It sets shared_buffers via ALTER SYSTEM + a cluster restart
# and resets to the default when done; if it is interrupted, reset it by hand
# with:  sudo bash reset_all_parameters.sh [version...]
# Everything except the buffer SIZES is configured here (DIR, RUNS, WARMUP,
# BATCHNUM, WORKERS, STATEMENT_TIMEOUT, PGVERS). NOTE: DIR defaults to the whole
# tpch corpus - scope it (e.g. DIR=queries/tpch/tpch-queries) unless you want a
# very long sweep, since it runs per size x version x database.
#   make test-shared-buffer                                  # tpch+tpch_idx, all versions
#   make test-shared-buffer PGVERS=18 DIR=queries/tpch/tpch-queries
#   make test-shared-buffer DRYRUN=1                          # print the plan only
SB_DBS  ?= tpch tpch_idx
SB_LOGS ?= logs/shared_buffers
test-shared-buffer:
	@$(SUDO_PRIME) \
	    || { echo "sudo authentication failed (override with: make test-shared-buffer SUDO_PASSWORD=...)"; exit 1; }; \
	  sudo -n modprobe msr 2>/dev/null || true; \
	  sudo -n env DBS="$(SB_DBS)" PGVERS="$(PGVERS)" DIR="$(DIR)" \
	    RUNS="$(RUNS)" WARMUP="$(WARMUP)" BATCHNUM="$(BATCHNUM)" WORKERS="$(WORKERS)" \
	    STATEMENT_TIMEOUT="$(STATEMENT_TIMEOUT)" LOGS_ROOT="$(SB_LOGS)" DRYRUN="$(DRYRUN)" \
	    bash test_shared_buffer.sh

# ----- work_mem sweep (warm-cache runs at several work_mem sizes) --------------
# test_work_mem.sh sweeps work_mem (4MB default, 16MB, 32MB, 64MB, 128MB - the
# SIZES live in the script) with shared_buffers, effective_cache_size and
# max_parallel_workers_per_gather PINNED (4GB / 12GB / 4 - overridable below), so
# work_mem is the only variable. It runs the warm-cache benchmark at each value
# on WM_DBS across PGVERS, writing each value's results to its own dir under
# WM_LOGS/wm_<size>/. The fixed knobs are applied via ALTER SYSTEM (+ one restart
# for shared_buffers); work_mem changes only reload the config. All four GUCs are
# reset to their defaults when done; if it is interrupted, reset by hand with:
#   sudo bash reset_all_parameters.sh [version...]
# Everything except the work_mem SIZES is configured here (DIR, RUNS, WARMUP,
# BATCHNUM, STATEMENT_TIMEOUT, PGVERS, and the three fixed knobs). NOTE: DIR
# defaults to the whole tpch corpus - scope it (e.g. DIR=queries/tpch/tpch-queries)
# unless you want a very long sweep, since it runs per size x version x database.
#   make test-work-mem                                    # tpch+tpch_idx, all versions
#   make test-work-mem PGVERS=18 DIR=queries/tpch/tpch-queries
#   make test-work-mem DRYRUN=1                            # print the plan only
WM_DBS  ?= tpch tpch_idx
WM_LOGS ?= logs/work_mem
WM_SHARED_BUFFERS                  ?= 4GB
WM_EFFECTIVE_CACHE_SIZE            ?= 12GB
WM_MAX_PARALLEL_WORKERS_PER_GATHER ?= 4
test-work-mem:
	@$(SUDO_PRIME) \
	    || { echo "sudo authentication failed (override with: make test-work-mem SUDO_PASSWORD=...)"; exit 1; }; \
	  sudo -n modprobe msr 2>/dev/null || true; \
	  sudo -n env DBS="$(WM_DBS)" PGVERS="$(PGVERS)" DIR="$(DIR)" \
	    RUNS="$(RUNS)" WARMUP="$(WARMUP)" BATCHNUM="$(BATCHNUM)" \
	    SHARED_BUFFERS="$(WM_SHARED_BUFFERS)" EFFECTIVE_CACHE_SIZE="$(WM_EFFECTIVE_CACHE_SIZE)" \
	    MAX_PARALLEL_WORKERS_PER_GATHER="$(WM_MAX_PARALLEL_WORKERS_PER_GATHER)" \
	    STATEMENT_TIMEOUT="$(STATEMENT_TIMEOUT)" LOGS_ROOT="$(WM_LOGS)" DRYRUN="$(DRYRUN)" \
	    bash test_work_mem.sh

# ----- effective_cache_size sweep (warm-cache runs at several ECS values) ------
# test_effective_cache_size.sh sweeps effective_cache_size (4GB, 8GB, 12GB - the
# VALUES live in the script) with shared_buffers, work_mem and
# max_parallel_workers_per_gather PINNED (4GB / 64MB / 4 - overridable below), so
# effective_cache_size is the only variable. effective_cache_size is a planner
# hint only (no allocation); this measures how the plans it steers move timing.
# Results go to ECS_LOGS/ecs_<size>/. All four GUCs reset to their defaults when
# done; if interrupted, reset by hand with:
#   sudo bash reset_all_parameters.sh [version...]
# NOTE: DIR defaults to the whole tpch corpus - scope it unless you want a very
# long sweep (runs per size x version x database).
#   make test-effective-cache-size                        # tpch+tpch_idx, all versions
#   make test-effective-cache-size PGVERS=18 DIR=queries/tpch/tpch-queries
#   make test-effective-cache-size DRYRUN=1               # print the plan only
ECS_DBS  ?= tpch tpch_idx
ECS_LOGS ?= logs/effective_cache_size
ECS_SHARED_BUFFERS                  ?= 4GB
ECS_WORK_MEM                        ?= 64MB
ECS_MAX_PARALLEL_WORKERS_PER_GATHER ?= 4
test-effective-cache-size:
	@$(SUDO_PRIME) \
	    || { echo "sudo authentication failed (override with: make test-effective-cache-size SUDO_PASSWORD=...)"; exit 1; }; \
	  sudo -n modprobe msr 2>/dev/null || true; \
	  sudo -n env DBS="$(ECS_DBS)" PGVERS="$(PGVERS)" DIR="$(DIR)" \
	    RUNS="$(RUNS)" WARMUP="$(WARMUP)" BATCHNUM="$(BATCHNUM)" \
	    SHARED_BUFFERS="$(ECS_SHARED_BUFFERS)" WORK_MEM="$(ECS_WORK_MEM)" \
	    MAX_PARALLEL_WORKERS_PER_GATHER="$(ECS_MAX_PARALLEL_WORKERS_PER_GATHER)" \
	    STATEMENT_TIMEOUT="$(STATEMENT_TIMEOUT)" LOGS_ROOT="$(ECS_LOGS)" DRYRUN="$(DRYRUN)" \
	    bash test_effective_cache_size.sh

# ----- max_parallel_workers_per_gather sweep (warm-cache runs at 2/4/6) --------
# test_max_parallel_workers_per_gather.sh sweeps max_parallel_workers_per_gather
# (2, 4, 6 - the VALUES live in the script) with shared_buffers,
# effective_cache_size and work_mem PINNED (4GB / 12GB / 64MB - overridable
# below), so parallelism is the only variable. Values above the cluster's
# max_parallel_workers / max_worker_processes (default 8) are clamped by PG.
# Results go to MPW_LOGS/mpw_<n>/. All four GUCs reset to their defaults when
# done; if interrupted, reset by hand with:
#   sudo bash reset_all_parameters.sh [version...]
# NOTE: DIR defaults to the whole tpch corpus - scope it unless you want a very
# long sweep (runs per value x version x database).
#   make test-max-parallel-workers                        # tpch+tpch_idx, all versions
#   make test-max-parallel-workers PGVERS=18 DIR=queries/tpch/tpch-queries
#   make test-max-parallel-workers DRYRUN=1               # print the plan only
MPW_DBS  ?= tpch tpch_idx
MPW_LOGS ?= logs/max_parallel_workers
MPW_SHARED_BUFFERS       ?= 4GB
MPW_EFFECTIVE_CACHE_SIZE ?= 12GB
MPW_WORK_MEM             ?= 64MB
test-max-parallel-workers:
	@$(SUDO_PRIME) \
	    || { echo "sudo authentication failed (override with: make test-max-parallel-workers SUDO_PASSWORD=...)"; exit 1; }; \
	  sudo -n modprobe msr 2>/dev/null || true; \
	  sudo -n env DBS="$(MPW_DBS)" PGVERS="$(PGVERS)" DIR="$(DIR)" \
	    RUNS="$(RUNS)" WARMUP="$(WARMUP)" BATCHNUM="$(BATCHNUM)" \
	    SHARED_BUFFERS="$(MPW_SHARED_BUFFERS)" EFFECTIVE_CACHE_SIZE="$(MPW_EFFECTIVE_CACHE_SIZE)" \
	    WORK_MEM="$(MPW_WORK_MEM)" \
	    STATEMENT_TIMEOUT="$(STATEMENT_TIMEOUT)" LOGS_ROOT="$(MPW_LOGS)" DRYRUN="$(DRYRUN)" \
	    bash test_max_parallel_workers_per_gather.sh

# ----- work_mem PLAN sweep (save query plans at each work_mem value) -----------
# work_mem_plans.sh mirrors test-work-mem but saves PLANS (plan_builder /
# `make plans`, i.e. EXPLAIN ANALYZE) instead of timings, sweeping work_mem (4MB,
# 16MB, 32MB, 64MB, 128MB - the SIZES live in the script) with shared_buffers,
# effective_cache_size and max_parallel_workers_per_gather PINNED (4GB / 12GB / 4
# - overridable below). Each value's plans land in their OWN root,
# PWM_PLANS/wm_<size>/<db>/, so nothing already in plans/ (plans/tpch,
# plans/tpch_idx) is overwritten. Both base (tpch) and indexed (tpch_idx) run.
# All four GUCs reset to their defaults when done; if interrupted, reset by hand:
#   sudo bash reset_all_parameters.sh [version...]
#   make plans-work-mem                                   # tpch+tpch_idx, all versions
#   make plans-work-mem PGVERS=18 DIR=queries/tpch/tpch-queries
#   make plans-work-mem DRYRUN=1                           # print the plan only
PWM_DBS   ?= tpch tpch_idx
PWM_PLANS ?= plans/work_mem
PWM_SHARED_BUFFERS                  ?= 4GB
PWM_EFFECTIVE_CACHE_SIZE            ?= 12GB
PWM_MAX_PARALLEL_WORKERS_PER_GATHER ?= 4
plans-work-mem:
	@$(SUDO_PRIME) \
	    || { echo "sudo authentication failed (override with: make plans-work-mem SUDO_PASSWORD=...)"; exit 1; }; \
	  sudo -n env DBS="$(PWM_DBS)" PGVERS="$(PGVERS)" DIR="$(DIR)" \
	    SHARED_BUFFERS="$(PWM_SHARED_BUFFERS)" EFFECTIVE_CACHE_SIZE="$(PWM_EFFECTIVE_CACHE_SIZE)" \
	    MAX_PARALLEL_WORKERS_PER_GATHER="$(PWM_MAX_PARALLEL_WORKERS_PER_GATHER)" \
	    PLANS_ROOT="$(PWM_PLANS)" DRYRUN="$(DRYRUN)" \
	    bash work_mem_plans.sh

# ----- hash_mem_multiplier sweep (warm-cache runs at several multipliers) ------
# test_hash_mem_multiplier.sh sweeps hash_mem_multiplier (2, 4, 8 - the VALUES
# live in the script) with the four established knobs PINNED (shared_buffers 4GB,
# effective_cache_size 12GB, work_mem 64MB, max_parallel_workers_per_gather 4 -
# overridable below), so the multiplier is the only variable. Results go to
# HMM_LOGS/hmm_<n>/. Resets all five GUCs when done; if interrupted:
#   sudo bash reset_all_parameters.sh [version...]
#   make test-hash-mem-multiplier                         # tpch+tpch_idx, all versions
#   make test-hash-mem-multiplier PGVERS=18 DIR=queries/tpch/tpch-queries
#   make test-hash-mem-multiplier DRYRUN=1                # print the plan only
HMM_DBS  ?= tpch tpch_idx
HMM_LOGS ?= logs/hash_mem_multiplier
HMM_SHARED_BUFFERS                  ?= 4GB
HMM_EFFECTIVE_CACHE_SIZE            ?= 12GB
HMM_WORK_MEM                        ?= 64MB
HMM_MAX_PARALLEL_WORKERS_PER_GATHER ?= 4
test-hash-mem-multiplier:
	@$(SUDO_PRIME) \
	    || { echo "sudo authentication failed (override with: make test-hash-mem-multiplier SUDO_PASSWORD=...)"; exit 1; }; \
	  sudo -n modprobe msr 2>/dev/null || true; \
	  sudo -n env DBS="$(HMM_DBS)" PGVERS="$(PGVERS)" DIR="$(DIR)" \
	    RUNS="$(RUNS)" WARMUP="$(WARMUP)" BATCHNUM="$(BATCHNUM)" \
	    SHARED_BUFFERS="$(HMM_SHARED_BUFFERS)" EFFECTIVE_CACHE_SIZE="$(HMM_EFFECTIVE_CACHE_SIZE)" \
	    WORK_MEM="$(HMM_WORK_MEM)" MAX_PARALLEL_WORKERS_PER_GATHER="$(HMM_MAX_PARALLEL_WORKERS_PER_GATHER)" \
	    STATEMENT_TIMEOUT="$(STATEMENT_TIMEOUT)" LOGS_ROOT="$(HMM_LOGS)" DRYRUN="$(DRYRUN)" \
	    bash test_hash_mem_multiplier.sh

# ----- parallel_leader_participation sweep (warm-cache runs at on vs off) ------
# test_parallel_leader_participation.sh runs the warm benchmark with
# parallel_leader_participation on and off, four knobs PINNED as above. Results
# go to PLP_LOGS/plp_<on|off>/. Resets all five GUCs when done.
#   make test-parallel-leader-participation
#   make test-parallel-leader-participation PGVERS=18 DIR=queries/tpch/tpch-queries
#   make test-parallel-leader-participation DRYRUN=1
PLP_DBS  ?= tpch tpch_idx
PLP_LOGS ?= logs/parallel_leader_participation
PLP_SHARED_BUFFERS                  ?= 4GB
PLP_EFFECTIVE_CACHE_SIZE            ?= 12GB
PLP_WORK_MEM                        ?= 64MB
PLP_MAX_PARALLEL_WORKERS_PER_GATHER ?= 4
test-parallel-leader-participation:
	@$(SUDO_PRIME) \
	    || { echo "sudo authentication failed (override with: make test-parallel-leader-participation SUDO_PASSWORD=...)"; exit 1; }; \
	  sudo -n modprobe msr 2>/dev/null || true; \
	  sudo -n env DBS="$(PLP_DBS)" PGVERS="$(PGVERS)" DIR="$(DIR)" \
	    RUNS="$(RUNS)" WARMUP="$(WARMUP)" BATCHNUM="$(BATCHNUM)" \
	    SHARED_BUFFERS="$(PLP_SHARED_BUFFERS)" EFFECTIVE_CACHE_SIZE="$(PLP_EFFECTIVE_CACHE_SIZE)" \
	    WORK_MEM="$(PLP_WORK_MEM)" MAX_PARALLEL_WORKERS_PER_GATHER="$(PLP_MAX_PARALLEL_WORKERS_PER_GATHER)" \
	    STATEMENT_TIMEOUT="$(STATEMENT_TIMEOUT)" LOGS_ROOT="$(PLP_LOGS)" DRYRUN="$(DRYRUN)" \
	    bash test_parallel_leader_participation.sh

# ----- effective_io_concurrency sweep (COLD-cache runs) -----------------------
# test_effective_io_concurrency.sh is a COLD sweep (OS cache dropped + cluster
# restarted before every query) across effective_io_concurrency (0, 16, 64, 256),
# four knobs PINNED as above. Results (query_cold_<db>.csv) go to EIC_LOGS/eic_<n>/.
# COLD runs are SLOW - scope DIR and keep RUNS small. Resets all five GUCs when done.
#   make test-effective-io-concurrency PGVERS=18 DIR=queries/tpch/tpch-queries
#   make test-effective-io-concurrency DRYRUN=1
EIC_DBS  ?= tpch tpch_idx
EIC_LOGS ?= logs/effective_io_concurrency
EIC_SHARED_BUFFERS                  ?= 4GB
EIC_EFFECTIVE_CACHE_SIZE            ?= 12GB
EIC_WORK_MEM                        ?= 64MB
EIC_MAX_PARALLEL_WORKERS_PER_GATHER ?= 4
test-effective-io-concurrency:
	@$(SUDO_PRIME) \
	    || { echo "sudo authentication failed (override with: make test-effective-io-concurrency SUDO_PASSWORD=...)"; exit 1; }; \
	  sudo -n modprobe msr 2>/dev/null || true; \
	  sudo -n env DBS="$(EIC_DBS)" PGVERS="$(PGVERS)" DIR="$(DIR)" RUNS="$(RUNS)" \
	    SHARED_BUFFERS="$(EIC_SHARED_BUFFERS)" EFFECTIVE_CACHE_SIZE="$(EIC_EFFECTIVE_CACHE_SIZE)" \
	    WORK_MEM="$(EIC_WORK_MEM)" MAX_PARALLEL_WORKERS_PER_GATHER="$(EIC_MAX_PARALLEL_WORKERS_PER_GATHER)" \
	    STATEMENT_TIMEOUT="$(STATEMENT_TIMEOUT)" LOGS_ROOT="$(EIC_LOGS)" DRYRUN="$(DRYRUN)" \
	    bash test_effective_io_concurrency.sh

# ----- io_combine_limit sweep (COLD-cache runs, PG18+) ------------------------
# test_io_combine_limit.sh is a COLD sweep across the I/O combine limit (128kB,
# 256kB, 1MB), setting BOTH io_max_combine_limit (POSTMASTER) and io_combine_limit,
# four knobs PINNED as above. PG18+ only (older versions are skipped). Results go
# to IOCL_LOGS/iocl_<size>/. COLD runs are SLOW. Resets all GUCs when done.
#   make test-io-combine-limit PGVERS=18 DIR=queries/tpch/tpch-queries
#   make test-io-combine-limit DRYRUN=1
IOCL_DBS  ?= tpch tpch_idx
IOCL_LOGS ?= logs/io_combine_limit
IOCL_SHARED_BUFFERS                  ?= 4GB
IOCL_EFFECTIVE_CACHE_SIZE            ?= 12GB
IOCL_WORK_MEM                        ?= 64MB
IOCL_MAX_PARALLEL_WORKERS_PER_GATHER ?= 4
test-io-combine-limit:
	@$(SUDO_PRIME) \
	    || { echo "sudo authentication failed (override with: make test-io-combine-limit SUDO_PASSWORD=...)"; exit 1; }; \
	  sudo -n modprobe msr 2>/dev/null || true; \
	  sudo -n env DBS="$(IOCL_DBS)" PGVERS="$(PGVERS)" DIR="$(DIR)" RUNS="$(RUNS)" \
	    SHARED_BUFFERS="$(IOCL_SHARED_BUFFERS)" EFFECTIVE_CACHE_SIZE="$(IOCL_EFFECTIVE_CACHE_SIZE)" \
	    WORK_MEM="$(IOCL_WORK_MEM)" MAX_PARALLEL_WORKERS_PER_GATHER="$(IOCL_MAX_PARALLEL_WORKERS_PER_GATHER)" \
	    STATEMENT_TIMEOUT="$(STATEMENT_TIMEOUT)" LOGS_ROOT="$(IOCL_LOGS)" DRYRUN="$(DRYRUN)" \
	    bash test_io_combine_limit.sh

# ----- io_method sweep (COLD-cache runs, PG18+) -------------------------------
# test_io_method.sh is a COLD sweep across the PG18 I/O method: worker with
# io_workers 1/3/6, io_uring, and sync; four knobs PINNED as above. PG18+ only
# (older versions are skipped; io_uring needs a liburing build or it is skipped).
# Results go to IOM_LOGS/iom_<config>/. COLD runs are SLOW. Resets all GUCs when done.
#   make test-io-method PGVERS=18 DIR=queries/tpch/tpch-queries
#   make test-io-method DRYRUN=1
IOM_DBS  ?= tpch tpch_idx
IOM_LOGS ?= logs/io_method
IOM_SHARED_BUFFERS                  ?= 4GB
IOM_EFFECTIVE_CACHE_SIZE            ?= 12GB
IOM_WORK_MEM                        ?= 64MB
IOM_MAX_PARALLEL_WORKERS_PER_GATHER ?= 4
test-io-method:
	@$(SUDO_PRIME) \
	    || { echo "sudo authentication failed (override with: make test-io-method SUDO_PASSWORD=...)"; exit 1; }; \
	  sudo -n modprobe msr 2>/dev/null || true; \
	  sudo -n env DBS="$(IOM_DBS)" PGVERS="$(PGVERS)" DIR="$(DIR)" RUNS="$(RUNS)" \
	    SHARED_BUFFERS="$(IOM_SHARED_BUFFERS)" EFFECTIVE_CACHE_SIZE="$(IOM_EFFECTIVE_CACHE_SIZE)" \
	    WORK_MEM="$(IOM_WORK_MEM)" MAX_PARALLEL_WORKERS_PER_GATHER="$(IOM_MAX_PARALLEL_WORKERS_PER_GATHER)" \
	    STATEMENT_TIMEOUT="$(STATEMENT_TIMEOUT)" LOGS_ROOT="$(IOM_LOGS)" DRYRUN="$(DRYRUN)" \
	    bash test_io_method.sh

# ----- set / reset the fixed "testing" GUCs -----------------------------------
# set-parameters applies the testing GUCs (shared_buffers 4GB, work_mem 64MB,
# effective_cache_size 12GB, effective_io_concurrency 64,
# max_parallel_workers_per_gather 4, io_combine_limit + io_max_combine_limit 1MB
# on PG18) via ALTER SYSTEM + restart; reset_all_parameters.sh undoes them.
# SET_VERS defaults to 18 (the version the io_* knobs need); widen it if wanted.
#   make set-parameters                    # PG18
#   make set-parameters SET_VERS="16 18"
SET_VERS ?= 18
set-parameters:
	@$(SUDO_PRIME) \
	    || { echo "sudo authentication failed (override with: make set-parameters SUDO_PASSWORD=...)"; exit 1; }; \
	  sudo -n bash set_test_parameters.sh $(SET_VERS)

# ----- warm step-up benchmark (per-query cold start, warm measurement) --------
# run_warm_stepup.sh runs every query in WSU_DIR REPEATS times in one saved
# RANDOM order; per entry it drops the OS cache + restarts, does WARMUP runs, then
# measures a step-up of batch sizes (WSU_BATCH_SIZES, N copies per psql process)
# WARM. Results land in WSU_LOGS/. Set the tuning GUCs FIRST (make set-parameters)
# and reset after. DRYRUN=1 generates+saves the order and runs nothing.
#   make set-parameters && make warm-stepup
#   make warm-stepup WSU_DB=tpch_idx           # the indexed database
#   make warm-stepup DRYRUN=1                   # just build+save the run order
#   make warm-stepup ORDER_FILE=logs/warm_stepup/run_order.txt   # replay an order
WSU_DIR         ?= queries/tpch/tpch-queries
WSU_DB          ?= tpch
WSU_PGVER       ?= 18
WSU_REPEATS     ?= 3
WSU_WARMUP      ?= 2
WSU_BATCH_SIZES ?= 1 2 4 8 16
WSU_RUNS        ?= 1
WSU_LOGS        ?= logs/warm_stepup
WSU_RUNID       ?=
ORDER_FILE      ?=
warm-stepup:
	@$(SUDO_PRIME) \
	    || { echo "sudo authentication failed (override with: make warm-stepup SUDO_PASSWORD=...)"; exit 1; }; \
	  sudo -n modprobe msr 2>/dev/null || true; \
	  sudo -n env DIR="$(WSU_DIR)" DB_NAME="$(WSU_DB)" PGVER="$(WSU_PGVER)" \
	    REPEATS="$(WSU_REPEATS)" WARMUP="$(WSU_WARMUP)" BATCH_SIZES="$(WSU_BATCH_SIZES)" \
	    RUNS="$(WSU_RUNS)" LOGS_ROOT="$(WSU_LOGS)" RUNID="$(WSU_RUNID)" \
	    STATEMENT_TIMEOUT="$(STATEMENT_TIMEOUT)" \
	    ORDER_FILE="$(ORDER_FILE)" DRYRUN="$(DRYRUN)" \
	    bash run_warm_stepup.sh

clean:
	rm -f $(TARGET) $(PLAN_TARGET) $(OUTPUT_TARGET) $(WRITE_TARGET) $(COLD_TARGET)
