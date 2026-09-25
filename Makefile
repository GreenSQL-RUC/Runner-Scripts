# ===== GreenSQL Makefile =====
#
# The single entry point. It fills in environment variables, primes sudo (RAPL
# and psql-as-postgres need root), loads the msr module, and runs one of the
# C runners in run/ (compiled into bin/) or one of the Bash drivers.
#
#   make                 build the runners into bin/
#   make help            list targets and knobs
#
# THE TWO MEASUREMENT MODES
#   make warm-stepup     the main benchmark: every query REPEATS times in one
#                        saved random order; per entry: cold start (cache drop +
#                        cluster restart), WARMUP warm-ups, then a measured batch
#                        step-up at BATCH_SIZES (N copies per psql process), warm.
#   make cold            cold-cache runs: cache drop + restart before EVERY
#                        execution, RUNS executions per query, no warmup/batches.
#
#   make run             one plain warm pass with query_runner (no restarts):
#                        WARMUP warm-ups then RUNS batches at each BATCH_SIZES
#                        size. BATCH_SIZES=1 WARMUP=1 RUNS=1 is the quick
#                        "does this suite work" test.
#
# ONE SET OF KNOBS, shared by every target (override on the command line):
#   PGVER=18 DB_NAME=tpch DIR=queries/tpch/tpch-queries LOGS_DIR=logs
#   WARMUP=2 BATCH_SIZES="1 16" RUNS=1 REPEATS=1 WORKERS= STATEMENT_TIMEOUT=900
#   PGVERS="15 16 17 18" DBS="tpch tpch_idx"        (multi-version / multi-db sweeps)
#   THERMAL_EQUALISE=0 FIX_CLOCK=0               (thermal protocol; OFF by default)
#   DRYRUN=1                                     (print the plan, run nothing)
#
#   make warm-stepup DB_NAME=tpch_idx REPEATS=3
#   make run DIR=queries/tpch/SQLStorm DB_NAME=tpch_idx WARMUP=1 BATCH_SIZES=1 STATEMENT_TIMEOUT=10
#   make cold DIR=queries/tpch/Core RUNS=5
#
# Layout:  build/ (data + query build scripts)   run/ (runners + run drivers)
#          test/  (parameter sweeps, consistency) bin/ (compiled runners)
#          queries/ (all SQL: tpch/, estat/, warehouse/, write/, slow/, equivalent/)

ROOT  := $(CURDIR)
BIN   := bin
RUN   := run
TEST  := test
BUILD := build

CC      = gcc
CFLAGS  = -O2 -Wall -Wextra
LDFLAGS = -lm -lpthread

# ---------------------------------------------------------------- knobs -----
# NOTE: no inline comments on value lines - GNU Make keeps the whitespace before
# an inline "#" as part of the value.

# Which PostgreSQL major. Each major has its own cluster on its own port, so
# the port IS the version selector; it is looked up rather than hard-coded.
PGVER  ?= 18
PGPORT ?= $(shell pg_lsclusters -h 2>/dev/null | awk -v v='$(PGVER)' '$$1 == v && $$2 == "main" { print $$3 }')
DB_NAME ?= tpch
DB_USER ?= postgres

# The query set (a directory, searched recursively, or a single .sql file).
DIR ?= queries/tpch/tpch-queries
# Where result CSVs go. warm-stepup and the sweeps make sub-folders under it.
LOGS_DIR ?= logs

# Warm measurement shape (query_runner):
#   WARMUP       unmeasured single-copy runs before measuring (0 disables)
#   BATCH_SIZES  measured batch sizes, N copies of the query in ONE psql process
#   RUNS         measured batches at each size
#   REPEATS      (warm-stepup / matrix only) passes over the query set, in one
#                random order across all passes
WARMUP      ?= 2
BATCH_SIZES ?= 1 16
RUNS        ?= 1
REPEATS     ?= 1

# max_parallel_workers_per_gather for every query; empty = the planner decides.
WORKERS ?=
# Seconds before the SERVER cancels one execution; empty = no limit.
STATEMENT_TIMEOUT ?= 900

# Multi-version / multi-database sweeps.
PGVERS ?= 15 16 17 18
DBS    ?= tpch tpch_idx

# warm-stepup: name this run's folder ($(LOGS_DIR)/warm_stepup/<RUNID>/), or
# replay a saved order file. Both default to "fresh".
RUNID      ?=
ORDER_FILE ?=

# Print the plan and change nothing (honoured by every driver/sweep).
DRYRUN ?=

# --- thermal protocol (see run/thermal_runner_brief.md). OFF by default. -----
#   THERMAL_EQUALISE  0 = off; 1 = temperature-gated start before each query
#                     (pre-heat below T_LO, wait above T_HI); burn = fixed
#                     PREHEAT_S all-core burn before each query
#   FIX_CLOCK         1 = pin the clock for the run (governor=performance and
#                     turbo off, i.e. capped at the base frequency), restored
#                     afterwards (also on Ctrl-C)
#   CLOCK_MAX_KHZ     with FIX_CLOCK=1, pin to this ceiling instead of the base
#                     frequency, e.g. 2500000 for 2.5 GHz. Above the base
#                     frequency turbo stays ENABLED and scaling_max_freq caps
#                     it. A cap is a ceiling, not a guarantee: package power
#                     limits can still hold the cores below it.
# Sensor columns (pkg temp, MHz, throttle counts) are ALWAYS logged.
THERMAL_EQUALISE ?= 0
T_LO             ?= 55
T_HI             ?= 60
PREHEAT_MAX_S    ?= 60
COOLDOWN_MAX_S   ?= 120
PREHEAT_S        ?= 30
FIX_CLOCK        ?= 0
CLOCK_MAX_KHZ    ?=
# Runtime-tiered batch cap for big suites: when set, a query whose warm 1-copy
# run takes longer than SLOW_COPY_SEC skips batch sizes above BATCH_CAP_SLOW.
BATCH_CAP_SLOW ?=
SLOW_COPY_SEC  ?= 1

# --- db-scale sweep (test-db-scale): TPC-H scale factors to step through -----
#   SCALES        scale factors (db tpch<SF>, "tpch" for 1) + DB_SUFFIX (e.g. _idx)
#   MAX_SPILL_PCT stop once this % of executions spill to temp files
#   BUILD_MISSING 1 = build a missing scale with build/build_tpch.sh if disk allows
#   SKIP_SET_PARAMS 1 = do not (re)apply the testing GUCs (no restart)
SCALES          ?= 1 2 5
DB_SUFFIX       ?=
MAX_SPILL_PCT   ?= 100
BUILD_MISSING   ?= 0
SKIP_SET_PARAMS ?= 0

# --- the pinned "testing" GUCs the sweeps hold constant --------------------
SHARED_BUFFERS                  ?= 4GB
EFFECTIVE_CACHE_SIZE            ?= 12GB
WORK_MEM                        ?= 64MB
MAX_PARALLEL_WORKERS_PER_GATHER ?= 4
# Versions set-parameters / reset-parameters act on (default: PGVER).
SET_VERS ?= $(PGVER)

# --- plans / outputs / write --------------------------------------------
PLANS_DIR   ?= plans
# APPEND=1: plan_builder appends a dated snapshot to each plan file instead of
# replacing it, and reports whether the plan shape changed (consistency test).
APPEND      ?=
OUTPUTS_DIR ?= outputs
MAX_ROWS    ?= 1000
# The write benchmark runs ONLY against a disposable scratch DB cloned from
# WRITE_TEMPLATE; write_runner refuses the canonical read databases.
WRITE_DB       ?= tpch_write
WRITE_TEMPLATE ?= tpch

# --- partial-archive filters ---------------------------------------------
QUERY ?=
VER   ?=
DB    ?=

# --- external power meter (optional) -------------------------------------
SIGLESS_ADDR    ?=
SIGLESS_CHANNEL ?= CH1

# Pre-authenticate sudo so runs never stop at a password prompt.
SUDO_PASSWORD ?= a
SUDO_PRIME    = printf '%s\n' '$(SUDO_PASSWORD)' | sudo -S -v >/dev/null 2>&1

# ---------------------------------------------------------- env bundles -----
# Everything a runner or driver needs, in one place. Scripts locate the repo
# through ROOT and the runners through BIN.
COMMON_ENV = ROOT="$(ROOT)" BIN="$(ROOT)/$(BIN)" PGVER="$(PGVER)" PGPORT="$(PGPORT)" \
             DB_NAME="$(DB_NAME)" DB_USER="$(DB_USER)" QUERY_DIR="$(DIR)" DIR="$(DIR)" \
             LOGS_DIR="$(LOGS_DIR)" WORKERS="$(WORKERS)" STATEMENT_TIMEOUT="$(STATEMENT_TIMEOUT)" \
             DRYRUN="$(DRYRUN)"

THERMAL_ENV = THERMAL_EQUALISE="$(THERMAL_EQUALISE)" T_LO="$(T_LO)" T_HI="$(T_HI)" \
              PREHEAT_MAX_S="$(PREHEAT_MAX_S)" COOLDOWN_MAX_S="$(COOLDOWN_MAX_S)" \
              PREHEAT_S="$(PREHEAT_S)" FIX_CLOCK="$(FIX_CLOCK)" \
              CLOCK_MAX_KHZ="$(CLOCK_MAX_KHZ)" \
              BATCH_CAP_SLOW="$(BATCH_CAP_SLOW)" SLOW_COPY_SEC="$(SLOW_COPY_SEC)"

WARM_ENV = $(COMMON_ENV) $(THERMAL_ENV) WARMUP="$(WARMUP)" BATCH_SIZES="$(BATCH_SIZES)" \
           RUNS="$(RUNS)" REPEATS="$(REPEATS)" RUNID="$(RUNID)" ORDER_FILE="$(ORDER_FILE)" \
           SIGLESS_ADDR="$(SIGLESS_ADDR)" SIGLESS_CHANNEL="$(SIGLESS_CHANNEL)"

SWEEP_ENV = $(WARM_ENV) PGVERS="$(PGVERS)" DBS="$(DBS)" \
            SHARED_BUFFERS="$(SHARED_BUFFERS)" EFFECTIVE_CACHE_SIZE="$(EFFECTIVE_CACHE_SIZE)" \
            WORK_MEM="$(WORK_MEM)" MAX_PARALLEL_WORKERS_PER_GATHER="$(MAX_PARALLEL_WORKERS_PER_GATHER)" \
            SCALES="$(SCALES)" DB_SUFFIX="$(DB_SUFFIX)" MAX_SPILL_PCT="$(MAX_SPILL_PCT)" \
            BUILD_MISSING="$(BUILD_MISSING)" SKIP_SET_PARAMS="$(SKIP_SET_PARAMS)"

# Run "$(2)" as root with the env bundle "$(1)": prime sudo, load msr for RAPL,
# then exec. One shell for prime + run, since sudo caches credentials per
# terminal and make would otherwise run each line in a fresh shell. FIX_CLOCK=1
# wraps the command in clock_control.sh, which pins the clock and restores it
# afterwards (the warm-stepup driver does this itself, so it is not wrapped).
CLOCK_WRAP = $(if $(filter 1,$(FIX_CLOCK)),bash $(RUN)/clock_control.sh with,)
SUDO_RUN = $(SUDO_PRIME) || { echo "sudo authentication failed (override with: make $@ SUDO_PASSWORD=...)"; exit 1; }; sudo -n modprobe msr 2>/dev/null || true; sudo -n env $(1) $(2)

# ---------------------------------------------------------------- build -----
RUNNERS = $(BIN)/query_runner $(BIN)/cold_runner $(BIN)/plan_builder $(BIN)/output_runner $(BIN)/write_runner

.DEFAULT_GOAL := all
.PHONY: all clean help pg-info check-pg run cold warm-stepup matrix matrix-plan \
        plans outputs write write-db index-build index-verify index-drop-db \
        set-parameters reset-parameters partial-archive plan-snapshots \
        planner-consistency fetch-sqlstorm build-stackoverflow plans-work-mem test-max-parallel-workers

all: $(RUNNERS)

$(BIN):
	mkdir -p $(BIN)

# query_runner, cold_runner and write_runner read RAPL, so they link rapl.c.
$(BIN)/query_runner: $(RUN)/query_runner.c $(RUN)/rapl.c $(RUN)/rapl.h | $(BIN)
	$(CC) $(CFLAGS) -o $@ $(RUN)/query_runner.c $(RUN)/rapl.c $(LDFLAGS)

$(BIN)/cold_runner: $(RUN)/cold_runner.c $(RUN)/rapl.c $(RUN)/rapl.h | $(BIN)
	$(CC) $(CFLAGS) -o $@ $(RUN)/cold_runner.c $(RUN)/rapl.c $(LDFLAGS)

$(BIN)/write_runner: $(RUN)/write_runner.c $(RUN)/rapl.c $(RUN)/rapl.h | $(BIN)
	$(CC) $(CFLAGS) -o $@ $(RUN)/write_runner.c $(RUN)/rapl.c $(LDFLAGS)

# plan_builder / output_runner need no RAPL.
$(BIN)/plan_builder: $(RUN)/plan_builder.c | $(BIN)
	$(CC) $(CFLAGS) -o $@ $<

$(BIN)/output_runner: $(RUN)/output_runner.c | $(BIN)
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(RUNNERS)

# ------------------------------------------------------------- cluster -----
pg-info:
	@pg_lsclusters
	@echo "PGVER=$(PGVER) -> PGPORT=$(PGPORT)"

# Fail early rather than silently measuring psql's default port.
check-pg:
	@if [ -z "$(PGPORT)" ]; then \
	    echo "No 'main' cluster for PostgreSQL $(PGVER). Installed clusters:"; \
	    pg_lsclusters; exit 1; \
	fi

# ------------------------------------------------------- measurement -----
# One plain warm pass: WARMUP warm-ups then RUNS batches at each BATCH_SIZES
# size, per query, no restarts. Rows -> $(LOGS_DIR)/query_{timing,samples,catalog}_<db>.csv
run: $(BIN)/query_runner check-pg
	@mkdir -p "$(LOGS_DIR)"; $(call SUDO_RUN,$(WARM_ENV),$(CLOCK_WRAP) $(BIN)/query_runner)

# Cold-cache runs: cache drop + cluster restart before EVERY execution, RUNS
# executions per query. Rows -> $(LOGS_DIR)/query_cold_<db>.csv
cold: $(BIN)/cold_runner check-pg
	@mkdir -p "$(LOGS_DIR)"; $(call SUDO_RUN,$(COMMON_ENV) RUNS="$(RUNS)",$(CLOCK_WRAP) $(BIN)/cold_runner)

# THE main benchmark (run/run_warm_stepup.sh). Set the testing GUCs first:
#   make set-parameters && make warm-stepup [DB_NAME=tpch_idx REPEATS=3]
#   make warm-stepup DRYRUN=1                      # save the order, run nothing
#   make warm-stepup ORDER_FILE=logs/warm_stepup/<RUNID>/run_order_<RUNID>.txt
# Everything lands in $(LOGS_DIR)/warm_stepup/<RUNID>/ (CSVs, order, summary).
warm-stepup: $(BIN)/query_runner check-pg
	@$(call SUDO_RUN,$(WARM_ENV),bash $(RUN)/run_warm_stepup.sh)

# Version x database sweep of warm-stepup, unattended and resumable.
#   make matrix-plan            # schedule + estimate only
#   make matrix PGVERS=18 DBS="tpch tpch_idx" REPEATS=3
matrix: $(BIN)/query_runner
	@$(call SUDO_RUN,$(SWEEP_ENV),bash $(RUN)/run_matrix.sh)

matrix-plan: $(BIN)/query_runner
	@$(call SUDO_RUN,$(SWEEP_ENV) DRYRUN=1,bash $(RUN)/run_matrix.sh)

# --------------------------------------------------- plans / outputs -----
# Save each query's EXPLAIN ANALYZE plan under $(PLANS_DIR)/<db>/ (no measuring).
# APPEND=1 keeps earlier snapshots in the same file and reports shape changes.
plans: $(BIN)/plan_builder check-pg
	@$(call SUDO_RUN,$(COMMON_ENV) PLANS_DIR="$(PLANS_DIR)" APPEND="$(APPEND)",$(BIN)/plan_builder)

# Save each query's result rows under $(OUTPUTS_DIR)/<db>/ (MAX_ROWS=0 = all).
outputs: $(BIN)/output_runner check-pg
	@$(call SUDO_RUN,$(COMMON_ENV) OUTPUTS_DIR="$(OUTPUTS_DIR)" MAX_ROWS="$(MAX_ROWS)",$(BIN)/output_runner)

# Plan-consistency check: `make plans APPEND=1` REPEATS times into one tree,
# then summarise which queries' plan shapes drifted (test/plan_snapshots.sh).
plan-snapshots: $(BIN)/plan_builder
	@$(call SUDO_RUN,$(SWEEP_ENV) PLANS_DIR="$(PLANS_DIR)",bash $(TEST)/plan_snapshots.sh)

# Cold/warm planner-consistency runs with plan hashes (test/planner_consistency.sh).
planner-consistency:
	@$(call SUDO_RUN,$(SWEEP_ENV) DB="$(DB_NAME)",bash $(TEST)/planner_consistency.sh)

# ------------------------------------------------------------- write -----
# write-db: (re)create the scratch DB as a clone of WRITE_TEMPLATE.
# write:    measure the write corpus (queries/write/<dataset>) against it.
#           ALWAYS cold: before every execution the file's SETUP section is
#           run, the scratch tables are quiesced (autovacuum off, CHECKPOINT),
#           caches are dropped and the cluster restarted; only the section
#           after @MEASURE is timed. RUNS executions per file, no batching,
#           no warm-up (a write cannot be repeated warm without drifting).
#           DRYRUN=1 skips the cache drop / restart (warm rows, plumbing test).
write-db: check-pg
	@$(SUDO_PRIME) || { echo "sudo authentication failed"; exit 1; }; \
	  sudo -n -u $(DB_USER) psql -p $(PGPORT) -d postgres -v ON_ERROR_STOP=1 -c \
	    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('$(WRITE_DB)','$(WRITE_TEMPLATE)') AND pid <> pg_backend_pid();" >/dev/null; \
	  sudo -n -u $(DB_USER) psql -p $(PGPORT) -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS $(WRITE_DB);" \
	    && sudo -n -u $(DB_USER) psql -p $(PGPORT) -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE $(WRITE_DB) TEMPLATE $(WRITE_TEMPLATE);" \
	    && echo "scratch DB '$(WRITE_DB)' (re)created from '$(WRITE_TEMPLATE)' on PostgreSQL $(PGVER) (port $(PGPORT))"

write: DIR = queries/write/tpch
write: $(BIN)/write_runner check-pg
	@mkdir -p "$(LOGS_DIR)"; $(call SUDO_RUN,$(COMMON_ENV) DB_NAME="$(WRITE_DB)" RUNS="$(RUNS)",$(CLOCK_WRAP) $(BIN)/write_runner)

# ----------------------------------------------------- indexed clones -----
# <db>_idx = template clone of <db> + the ixtest_ index suite, for DBS x PGVERS.
#   make index-build PGVERS=18 DBS=tpch   |   make index-build DRYRUN=1
index-build:
	@$(SUDO_PRIME) || { echo "sudo authentication failed"; exit 1; }; \
	  sudo -n env ROOT="$(ROOT)" INDEX_SCHEMA="$(ROOT)/schema/index_schema_tpch.sql" FORCE="$(FORCE)" DRYRUN="$(DRYRUN)" \
	    bash $(BUILD)/build_tpch_indexed.sh "$(DBS)" "$(PGVERS)"

index-verify: check-pg
	@$(SUDO_PRIME) || { echo "sudo authentication failed"; exit 1; }; \
	  sudo -n -u $(DB_USER) psql -p $(PGPORT) -d $(DB_NAME) -c \
	    "SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) AS size FROM pg_stat_user_indexes WHERE indexrelname LIKE 'ixtest_%' ORDER BY 1;"

index-drop-db:
	@$(SUDO_PRIME) || { echo "sudo authentication failed"; exit 1; }; \
	  for db in $(DBS); do \
	    sudo -n -u $(DB_USER) psql -p $(PGPORT) -d postgres -c "DROP DATABASE IF EXISTS $${db}_idx;"; \
	  done

# ------------------------------------------------ testing parameters -----
# Apply / undo the fixed testing GUCs on SET_VERS (default: PGVER).
set-parameters:
	@$(SUDO_PRIME) || { echo "sudo authentication failed"; exit 1; }; \
	  sudo -n bash $(RUN)/set_test_parameters.sh $(SET_VERS)

reset-parameters:
	@$(SUDO_PRIME) || { echo "sudo authentication failed"; exit 1; }; \
	  sudo -n env EXTRA_PARAMS="effective_io_concurrency io_combine_limit io_max_combine_limit" \
	    bash $(RUN)/reset_all_parameters.sh $(SET_VERS)

# ----------------------------------------------------- parameter sweeps -----
# test-<name> runs test/test_<name>.sh (dashes -> underscores). Each sweeps ONE
# GUC with the others pinned to the testing values above, writing every value's
# results to its own $(LOGS_DIR)/<param>/<tag>/ folder, and resets on exit.
#   make test-work-mem PGVERS=18 DIR=queries/tpch/tpch-queries
#   make test-shared-buffer DRYRUN=1
# Available: test-shared-buffer test-work-mem test-effective-cache-size
#   test-max-parallel-workers-per-gather test-hash-mem-multiplier
#   test-parallel-leader-participation test-effective-io-concurrency (cold)
#   test-io-combine-limit (cold, PG18+) test-io-method (cold, PG18+)
#   test-db-scale (spill rate vs TPC-H scale factor: SCALES, DB_SUFFIX, MAX_SPILL_PCT)
test-%: $(BIN)/query_runner $(BIN)/cold_runner
	@[ -f "$(TEST)/test_$(subst -,_,$*).sh" ] || { echo "no such sweep: $(TEST)/test_$(subst -,_,$*).sh"; exit 1; }; \
	  $(call SUDO_RUN,$(SWEEP_ENV),bash $(TEST)/test_$(subst -,_,$*).sh)

test-max-parallel-workers: test-max-parallel-workers-per-gather

# work_mem sweep saving PLANS (not timings) under $(PLANS_DIR)/work_mem/wm_<size>/<db>/.
plans-work-mem: $(BIN)/plan_builder
	@$(call SUDO_RUN,$(SWEEP_ENV) PLANS_ROOT="$(PLANS_DIR)/work_mem",bash $(TEST)/work_mem_plans.sh)

# ------------------------------------------------------------ utilities -----
# Move a query's or a run's rows out of the live CSVs into archive/partial/
# (reversible). Needs QUERY=<substring> and/or RUNID=<run_id>.
partial-archive:
	@[ -n "$(QUERY)" ] || [ -n "$(RUNID)" ] || { echo "usage: make partial-archive { QUERY=<name> | RUNID=<id> } [VER=<pgver>] [DB=<db>] [DRYRUN=1]"; exit 1; }
	@$(SUDO_PRIME) || { echo "sudo authentication failed"; exit 1; }; \
	  sudo -n env ROOT="$(ROOT)" QUERY="$(QUERY)" RUNID="$(RUNID)" VER="$(VER)" DB="$(DB)" DRYRUN="$(DRYRUN)" LOGS_DIR="$(LOGS_DIR)" \
	    bash $(RUN)/archive_partial.sh

# Fetch a SQLStorm query set into queries/<dataset>/SQLStorm/:
# SQLSTORM_DATASET=tpch (~17k, default) or stackoverflow (valid queries only).
SQLSTORM_DATASET ?= tpch
fetch-sqlstorm:
	@SQLSTORM_DATASET="$(SQLSTORM_DATASET)" FORCE="$(FORCE)" bash $(BUILD)/fetch_sqlstorm_queries.sh

# Build the SQLStorm StackOverflow database (download + load, no foreign keys)
# and fetch its valid query set. SO_SIZE=1gb|12gb|222gb; SO_DB defaults to
# stackoverflow_<size>. FORCE=1 rebuilds an existing database.
SO_SIZE ?= 1gb
SO_DB   ?=
build-stackoverflow:
	@$(SUDO_PRIME) || { echo "sudo authentication failed"; exit 1; }; \
	  sudo -n env FORCE="$(FORCE)" KEEP_ARCHIVE="$(KEEP_ARCHIVE)" DOWNLOAD_ONLY="$(DOWNLOAD_ONLY)" \
	    SKIP_QUERIES="$(SKIP_QUERIES)" SKIP_DISK_CHECK="$(SKIP_DISK_CHECK)" \
	    bash $(BUILD)/build_stackoverflow.sh "$(SO_SIZE)" "$(SO_DB)" "$(PGVER)"

help:
	@echo "targets:"
	@echo "  all | clean              build the runners into bin/ | remove them"
	@echo "  warm-stepup              the main benchmark (per-query cold start, warm step-up)"
	@echo "  cold                     cold-cache runs (restart before every execution)"
	@echo "  run                      one plain warm pass (quick suite check)"
	@echo "  matrix | matrix-plan     warm-stepup over PGVERS x DBS (resumable) | schedule only"
	@echo "  plans | outputs          save EXPLAIN ANALYZE plans (APPEND=1 keeps history) | result rows"
	@echo "  plan-snapshots           repeated plans APPEND=1, then a drift summary"
	@echo "  planner-consistency      cold/warm planner drift with plan hashes"
	@echo "  set-parameters | reset-parameters   apply | undo the fixed testing GUCs"
	@echo "  test-<name>              one-GUC sweep (see 'parameter sweeps' in the Makefile)"
	@echo "  test-db-scale            spill rate vs TPC-H scale factor (SCALES=, DB_SUFFIX=, MAX_SPILL_PCT=)"
	@echo "  plans-work-mem           plans at each work_mem value"
	@echo "  write | write-db         cold write benchmark (restart before every execution) | rebuild its scratch DB"
	@echo "  index-build | index-verify | index-drop-db   the <db>_idx clones"
	@echo "  partial-archive          pull rows out of the live CSVs (QUERY= / RUNID=)"
	@echo "  fetch-sqlstorm           download a SQLStorm query set (SQLSTORM_DATASET=tpch|stackoverflow)"
	@echo "  build-stackoverflow      download + load the StackOverflow DB and its queries (SO_SIZE=1gb|12gb|222gb)"
	@echo "  pg-info | check-pg       clusters and which port PGVER resolves to"
	@echo
	@echo "knobs (current values):"
	@echo "  PGVER=$(PGVER) (port $(PGPORT))  DB_NAME=$(DB_NAME)  DIR=$(DIR)  LOGS_DIR=$(LOGS_DIR)"
	@echo "  WARMUP=$(WARMUP)  BATCH_SIZES='$(BATCH_SIZES)'  RUNS=$(RUNS)  REPEATS=$(REPEATS)"
	@echo "  WORKERS='$(WORKERS)'  STATEMENT_TIMEOUT=$(STATEMENT_TIMEOUT)  PGVERS='$(PGVERS)'  DBS='$(DBS)'"
	@echo "  THERMAL_EQUALISE=$(THERMAL_EQUALISE) (T_LO=$(T_LO) T_HI=$(T_HI))  FIX_CLOCK=$(FIX_CLOCK) CLOCK_MAX_KHZ='$(CLOCK_MAX_KHZ)'  BATCH_CAP_SLOW='$(BATCH_CAP_SLOW)'"
	@echo "  DRYRUN='$(DRYRUN)'  SUDO_PASSWORD=(set)"
