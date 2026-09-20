#!/usr/bin/env bash
#
# test_db_scale.sh - how large can the database get before the workload spills?
#
# With the fixed testing GUCs applied (shared_buffers=4GB, work_mem=64MB, ...),
# run the same warm benchmark against TPC-H at ever-increasing scale factors
# and log the SPILL RATE at each: how many executions overflowed work_mem into
# temp files, how many blocks they wrote, and how much of the data still came
# from the buffer cache. The summary (one row per scale) is what tells you the
# largest scale that is still "acceptable" for this configuration.
#
# Per scale factor SF (database tpch<SF>, "tpch" for SF1, plus DB_SUFFIX e.g.
# _idx for the indexed clones):
#   1. if the database is missing: build it with build/build_tpch.sh when
#      BUILD_MISSING=1 AND enough disk is free (NEED_GB_PER_SF x SF), else skip
#      it with a note - so the sweep is safe to launch on a full disk;
#   2. `make run` (warm: WARMUP + BATCH_SIZES x RUNS) on DIR, logging to
#      $LOGS_ROOT/sf_<SF>/;
#   3. summarise that run's query_samples_<db>.csv into
#      $LOGS_ROOT/db_scale_summary.csv (appended, one row per scale):
#        spill_pct            % of executions with temp_written_blks > 0
#        temp_written_mb_exec temp blocks written per execution, in MB
#        shared_hit_pct       shared_hit / (shared_hit + shared_read)
#        read_mb_exec         blocks read from the OS/disk per execution, MB
#        queries_spilling     which queries spilled (';'-separated)
#   4. stop early once spill_pct exceeds MAX_SPILL_PCT (default: never).
#
# The testing GUCs are applied with run/set_test_parameters.sh at the start
# (a restart) and reset on exit, like the other sweeps. SKIP_SET_PARAMS=1 uses
# whatever is set (no restart) - e.g. when set-parameters was already run.
#
#   make test-db-scale SCALES="1 2 5" DB_SUFFIX=_idx PGVER=18
#   make test-db-scale DRYRUN=1                     # plan only, touches nothing
#   SUMMARY_ONLY=<samples.csv> SF=5 bash test/test_db_scale.sh   # just the metrics
#
# ENV: SCALES (default "1 2 5") DB_SUFFIX ("") PGVER (18) DIR
# (queries/tpch/tpch-queries) WARMUP (1) BATCH_SIZES ("1") RUNS (1)
# STATEMENT_TIMEOUT (900) LOGS_ROOT ($LOGS_DIR/db_scale) MAX_SPILL_PCT (100)
# BUILD_MISSING (0) NEED_GB_PER_SF (3) SKIP_SET_PARAMS (0) DRYRUN (0)
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"          # repo root (this script lives in test/)
cd "$ROOT" || exit 1

SCALES="${SCALES:-1 2 5}"
DB_SUFFIX="${DB_SUFFIX:-}"
PGVER="${PGVER:-18}"
DIR="${DIR:-queries/tpch/tpch-queries}"
WARMUP="${WARMUP:-1}"
BATCH_SIZES="${BATCH_SIZES:-1}"
RUNS="${RUNS:-1}"
STATEMENT_TIMEOUT="${STATEMENT_TIMEOUT:-900}"
LOGS_ROOT="${LOGS_ROOT:-${LOGS_DIR:-logs}/db_scale}"
MAX_SPILL_PCT="${MAX_SPILL_PCT:-100}"
BUILD_MISSING="${BUILD_MISSING:-0}"
NEED_GB_PER_SF="${NEED_GB_PER_SF:-3}"
SKIP_SET_PARAMS="${SKIP_SET_PARAMS:-0}"
DRYRUN="${DRYRUN:-0}"; [ "$DRYRUN" = "" ] && DRYRUN=0
SUMMARY="$LOGS_ROOT/db_scale_summary.csv"
SUMMARY_HDR="timestamp_utc,pg_version,sf,db,db_size_gb,shared_buffers,work_mem,executions,spill_execs,spill_pct,temp_written_mb_exec,shared_hit_pct,read_mb_exec,mean_elapsed_sec,queries_spilling"

port_of(){ pg_lsclusters -h | awk -v v="$1" '$1==v && $2=="main"{print $3}'; }
pgq(){ sudo -u postgres psql -p "$1" -d "${3:-postgres}" -tAc "$2" 2>/dev/null; }
db_of(){ local sf="$1"; [ "$sf" = 1 ] && echo "tpch$DB_SUFFIX" || echo "tpch${sf}$DB_SUFFIX"; }

# ---- the metric: spill rate from a samples CSV ----------------------------
# Columns (by name, so column additions never break this): temp_written_blks,
# temp_read_blks, shared_hit_blks, shared_read_blks, query, phase. Only
# measured executions count (warm-ups are excluded). Blocks are 8 kB.
summarise_spill(){   # samples.csv -> "executions,spill_execs,spill_pct,temp_mb_exec,hit_pct,read_mb_exec,queries"
    awk -F, '
        NR==1 { for (i=1;i<=NF;i++) c[$i]=i; next }
        $c["phase"]!="measured" { next }
        { n++
          tw=$c["temp_written_blks"]+0; hit=$c["shared_hit_blks"]+0; rd=$c["shared_read_blks"]+0
          temp+=tw; hits+=hit; reads+=rd
          if (tw>0) { s++; if (!(($c["query"]) in sq)) { sq[$c["query"]]=1; ql=ql (ql?";":"") $c["query"] } }
        }
        END {
          if (n==0) { print "0,0,,,,,"; exit }
          printf "%d,%d,%.2f,%.3f,%.2f,%.3f,%s\n", n, s, 100*s/n, temp*8/1024/n,
                 ((hits+reads)>0 ? 100*hits/(hits+reads) : 0), reads*8/1024/n, ql
        }' "$1"
}
mean_elapsed(){   # timing.csv -> mean elapsed_sec of measured batches
    awk -F, 'NR==1{for(i=1;i<=NF;i++)c[$i]=i;next} $c["phase"]=="measured"{s+=$c["elapsed_sec"];n++} END{if(n)printf "%.3f",s/n}' "$1"
}

# SUMMARY_ONLY=<samples.csv>: print the metrics for one file and exit (for
# re-analysing an old run, or testing the metric without running anything).
if [ -n "${SUMMARY_ONLY:-}" ]; then
    echo "executions,spill_execs,spill_pct,temp_written_mb_exec,shared_hit_pct,read_mb_exec,queries_spilling"
    summarise_spill "$SUMMARY_ONLY"
    exit 0
fi

PORT="$(port_of "$PGVER")"
[ -n "$PORT" ] || { echo "!! no PG$PGVER 'main' cluster; aborting" >&2; exit 1; }
if [ "$DRYRUN" != 1 ] && [ "$(id -u)" != 0 ]; then
    echo "!! must run as root (ALTER SYSTEM, restarts, RAPL); use sudo / make test-db-scale" >&2; exit 1
fi

# Free disk on the cluster's data volume, for the build-if-missing decision.
datadir="$(pg_lsclusters -h | awk -v v="$PGVER" '$1==v && $2=="main"{print $6}')"
free_gb=$(df -BG --output=avail "${datadir:-/}" 2>/dev/null | tail -1 | tr -dc '0-9')
free_gb=${free_gb:-0}

cleanup(){
    [ "$DRYRUN" = 1 ] && return
    [ "$SKIP_SET_PARAMS" = 1 ] && return
    echo; echo "==> resetting the testing parameters to default"
    EXTRA_PARAMS="effective_io_concurrency io_combine_limit io_max_combine_limit" bash "$ROOT/run/reset_all_parameters.sh" "$PGVER"
}
trap cleanup EXIT INT TERM

echo "db-scale sweep: PG$PGVER (port $PORT)  scales='$SCALES'  suffix='$DB_SUFFIX'  DIR=$DIR"
echo "  warm run per scale: WARMUP=$WARMUP BATCH_SIZES='$BATCH_SIZES' RUNS=$RUNS  stop when spill > ${MAX_SPILL_PCT}%"
echo "  build missing DBs: $([ "$BUILD_MISSING" = 1 ] && echo "yes (needs ${NEED_GB_PER_SF} GB x SF; ${free_gb} GB free on ${datadir:-?})" || echo "no (BUILD_MISSING=1 to enable)")"
echo "  logs -> $LOGS_ROOT/sf_<SF>/   summary -> $SUMMARY$([ "$DRYRUN" = 1 ] && echo '   [DRY RUN]')"

# ---- plan: which scales can actually run ------------------------------------
PLAN=()
for sf in $SCALES; do
    db="$(db_of "$sf")"
    if [ "$(pgq "$PORT" "SELECT 1 FROM pg_database WHERE datname='$db';")" = "1" ]; then
        PLAN+=("$sf:$db:present"); echo "  SF$sf  $db  present"
    elif [ "$BUILD_MISSING" = 1 ] && [ "$free_gb" -ge $((NEED_GB_PER_SF * sf)) ]; then
        PLAN+=("$sf:$db:build");   echo "  SF$sf  $db  missing -> will build (~$((NEED_GB_PER_SF * sf)) GB)"
    else
        echo "  SF$sf  $db  missing -> SKIP ($([ "$BUILD_MISSING" = 1 ] && echo "only ${free_gb} GB free, need $((NEED_GB_PER_SF * sf))" || echo "BUILD_MISSING=0"))"
    fi
done
[ ${#PLAN[@]} -gt 0 ] || { echo "!! nothing to run"; exit 1; }

if [ "$DRYRUN" = 1 ]; then
    echo "  [DRY RUN] would apply the testing GUCs$([ "$SKIP_SET_PARAMS" = 1 ] && echo ' (skipped: SKIP_SET_PARAMS=1)'), then per scale: make run -> summarise spill."
    exit 0
fi

# ---- apply the testing GUCs once (restart) ---------------------------------
if [ "$SKIP_SET_PARAMS" != 1 ]; then
    echo "==> applying the testing parameters on PG$PGVER"
    bash "$ROOT/run/set_test_parameters.sh" "$PGVER" || { echo "!! set_test_parameters failed"; exit 1; }
fi
sb="$(pgq "$PORT" "SHOW shared_buffers;")"; wm="$(pgq "$PORT" "SHOW work_mem;")"
pgver_full="$(pgq "$PORT" "SHOW server_version;" | cut -d' ' -f1)"
echo "  shared_buffers=$sb  work_mem=$wm"

mkdir -p "$LOGS_ROOT"
[ -f "$SUMMARY" ] || echo "$SUMMARY_HDR" > "$SUMMARY"

# ---- the sweep ---------------------------------------------------------------
for entry in "${PLAN[@]}"; do
    IFS=: read -r sf db state <<< "$entry"
    echo; echo "===== SF$sf  ($db) ====="
    if [ "$state" = build ]; then
        base="${db%$DB_SUFFIX}"
        echo "  building $base (SF$sf) on PG$PGVER"
        if ! bash "$ROOT/build/build_tpch.sh" "$sf" "$base" "$PGVER"; then echo "  !! build failed; skipping SF$sf"; continue; fi
        if [ -n "$DB_SUFFIX" ]; then
            INDEX_SCHEMA="$ROOT/schema/index_schema_tpch.sql" bash "$ROOT/build/build_tpch_indexed.sh" "$base" "$PGVER" \
                || { echo "  !! indexed clone failed; skipping SF$sf"; continue; }
        fi
    fi
    logdir="$LOGS_ROOT/sf_${sf}"
    mkdir -p "$logdir"
    if ! make -C "$ROOT" run PGVER="$PGVER" DB_NAME="$db" DIR="$DIR" WARMUP="$WARMUP" BATCH_SIZES="$BATCH_SIZES" \
             RUNS="$RUNS" WORKERS="" STATEMENT_TIMEOUT="$STATEMENT_TIMEOUT" LOGS_DIR="$logdir" \
             > "$logdir/run_pg${PGVER}_${db}.log" 2>&1; then
        echo "  !! make run failed (see $logdir/run_pg${PGVER}_${db}.log); skipping SF$sf"; continue
    fi
    samples="$logdir/query_samples_${db}.csv"; timing="$logdir/query_timing_${db}.csv"
    metrics="$(summarise_spill "$samples")"
    size_gb="$(pgq "$PORT" "SELECT round(pg_database_size('$db')/1024.0^3, 2);")"
    row="$(date -u +%Y-%m-%dT%H:%M:%SZ),$pgver_full,$sf,$db,$size_gb,$sb,$wm,$metrics"
    # mean_elapsed sits before queries_spilling: splice it in.
    row="$(echo "$row" | awk -F, -v me="$(mean_elapsed "$timing")" 'BEGIN{OFS=","} {q=$NF; NF--; print $0, me, q}')"
    echo "$row" >> "$SUMMARY"
    IFS=, read -r _ _ _ _ _ _ _ execs spills pct tmb hit rmb _ _ <<< "$row"
    echo "  executions=$execs  spilled=$spills (${pct}%)  temp_written=${tmb} MB/exec  shared_hit=${hit}%  read=${rmb} MB/exec  db=${size_gb} GB"
    if awk -v p="$pct" -v m="$MAX_SPILL_PCT" 'BEGIN{exit !(p+0 > m+0)}'; then
        echo "  spill ${pct}% exceeds MAX_SPILL_PCT=${MAX_SPILL_PCT}% - stopping: SF$sf is past the acceptable size"
        break
    fi
done

echo; echo "===== db-scale summary ($SUMMARY) ====="
column -s, -t < "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
# cleanup() resets the testing parameters on EXIT.
