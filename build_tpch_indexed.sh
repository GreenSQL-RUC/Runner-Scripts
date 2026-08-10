#!/usr/bin/env bash
#
# build_tpch_indexed.sh [databases] [pg_versions]
#
# Build indexed clones (<db>_idx) of TPC-H databases across one or more
# PostgreSQL versions - architecture B of INDEXED_TEST_PLAN.md. Each <db>_idx is
# a physical TEMPLATE clone of <db> (the base DB is used ONLY as a template and
# is never modified) plus the extensive ixtest_ index suite (index_schema_tpch.sql),
# then ANALYZEd. The base DBs stay the clean, minimal-index baseline.
#
# Loops every (version x database) combination. Existing _idx DBs are SKIPPED, so
# it is safe to re-run / resume (FORCE=1 rebuilds them). A base DB missing on a
# cluster is skipped with a warning. DRYRUN=1 prints the plan and builds nothing.
#
# Run as root so the inner "sudo -u postgres" needs no password:
#   sudo bash build_tpch_indexed.sh                      # tpch/tpch2/tpch5 on 14/16/18
#   sudo bash build_tpch_indexed.sh "tpch" "18"          # one db, one version
#   sudo bash build_tpch_indexed.sh "tpch tpch5" "16 18" # a subset
#   sudo FORCE=1 bash build_tpch_indexed.sh "tpch" "18"  # rebuild existing
#   sudo DRYRUN=1 bash build_tpch_indexed.sh             # show the plan only
#
# DISK: a full 3x3 matrix of _idx DBs is large (SF1/2/5 idx ~2/4/10 GB per
# version). Scope with the arguments if disk is tight.
#
set -euo pipefail

DBS="${1:-tpch tpch2 tpch5}"
VERS="${2:-14 16 18}"

HERE="$(cd "$(dirname "$0")" && pwd)"
SCHEMA="${INDEX_SCHEMA:-$HERE/index_schema_tpch.sql}"
PGUSER=postgres

[ -f "$SCHEMA" ] || { echo "index schema not found: $SCHEMA" >&2; exit 1; }

port_of() { pg_lsclusters -h | awk -v v="$1" '$1 == v && $2 == "main" { print $3 }'; }
db_exists() {
    [ "$(sudo -u "$PGUSER" psql -p "$1" -d postgres -tAc \
         "SELECT 1 FROM pg_database WHERE datname='$2';" 2>/dev/null)" = "1" ]
}

# Clone one base DB into <idx> on <port> and apply the index suite.
build_one() {
    local base="$1" idx="$2" ver="$3" port="$4" t0 isz ix
    local pg=(sudo -u "$PGUSER" psql -p "$port" -v ON_ERROR_STOP=1)

    echo "==> [$idx PG$ver] cloning $base (port $port)"
    # A TEMPLATE copy needs NO active connections to the source or target.
    "${pg[@]}" -d postgres -c \
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
        WHERE datname IN ('$base','$idx') AND pid <> pg_backend_pid();" >/dev/null
    "${pg[@]}" -d postgres -c "DROP DATABASE IF EXISTS $idx;"
    "${pg[@]}" -d postgres -c "CREATE DATABASE $idx TEMPLATE $base;"

    echo "==> [$idx PG$ver] applying index suite ($(basename "$SCHEMA"))"
    t0=$(date +%s)
    "${pg[@]}" -d "$idx" -f "$SCHEMA"
    echo "    indexes built in $(($(date +%s) - t0))s"

    "${pg[@]}" -d "$idx" -c "ANALYZE;" >/dev/null
    isz=$("${pg[@]}" -d postgres -tAc "SELECT pg_size_pretty(pg_database_size('$idx'));")
    ix=$("${pg[@]}" -d "$idx" -tAc \
      "SELECT count(*)||' indexes, '||pg_size_pretty(coalesce(sum(pg_relation_size(indexrelid)),0))
         FROM pg_stat_user_indexes WHERE indexrelname LIKE 'ixtest_%';")
    echo "    [$idx PG$ver] DONE: $isz  (ixtest_: $ix)"
}

built=0; skipped=0; missing=0; would=0
for ver in $VERS; do
    port="$(port_of "$ver")"
    if [ -z "$port" ]; then
        echo "!! no 'main' cluster for PostgreSQL $ver, skipping" >&2
        continue
    fi
    for db in $DBS; do
        idx="${db}_idx"
        if ! db_exists "$port" "$db"; then
            echo "-- [$idx PG$ver] base '$db' not present on port $port, skipping"
            missing=$((missing + 1)); continue
        fi
        if [ "${FORCE:-0}" != "1" ] && db_exists "$port" "$idx"; then
            echo "== [$idx PG$ver] already exists, skipping (FORCE=1 to rebuild)"
            skipped=$((skipped + 1)); continue
        fi
        if [ "${DRYRUN:-0}" = "1" ]; then
            echo "++ [$idx PG$ver] WOULD build (clone $db on port $port + index suite)"
            would=$((would + 1)); continue
        fi
        build_one "$db" "$idx" "$ver" "$port"
        built=$((built + 1))
    done
done

echo
if [ "${DRYRUN:-0}" = "1" ]; then
    echo "plan: would build $would, skip $skipped existing, $missing base(s) missing"
else
    echo "done: built $built, skipped $skipped existing, $missing base(s) missing"
fi
