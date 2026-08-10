#!/usr/bin/env bash
#
# build_tpch.sh <scale_factor> <db_name> [pg_version]
#
# Generates TPC-H data at <scale_factor> and loads it into a fresh <db_name>,
# on the cluster of [pg_version] (default 16). Each installed major version runs
# its own cluster on its own port, so the same database name can exist on all of
# them and be compared version against version.
# A clean, parameterised replacement for the (broken) `setup` target in the old
# Makefile. The two bugs that target had:
#   1. `./dbgen -s N` with no -f hangs on interactive "overwrite?" prompts when
#      .tbl files already exist -> we pass -f.
#   2. the load step ran psql without cd'ing to the data dir, so the \copy paths
#      did not resolve -> we stream each file by absolute path instead.
#
# Loads the 8 core TPC-H tables + the 3 indexes + get_tax_rate(). It does NOT
# create lineitem2_unindexed or CLUSTER lineitem (unused by the runner queries
# and very disk/time heavy at large scale factors).
#
# Run it as root so the inner "sudo -u postgres" needs no password:
#   sudo bash build_tpch.sh 5 tpch5        # on the default (16) cluster
#   sudo bash build_tpch.sh 5 tpch5 18     # on the PostgreSQL 18 cluster
#
set -euo pipefail

SF="${1:?usage: build_tpch.sh <scale_factor> <db_name> [pg_version]}"
DB="${2:?usage: build_tpch.sh <scale_factor> <db_name> [pg_version]}"
PGVER="${3:-16}"

HERE="$(cd "$(dirname "$0")" && pwd)"
DBGEN_DIR="$HERE/tpch-dbgen"
SCHEMA="$HERE/schema/tpch_schema.sql"
PGUSER=postgres
TABLES="region nation supplier customer part partsupp orders lineitem"

# tpch-dbgen is fetched on demand rather than committed (it is in .gitignore), so
# a fresh clone of THIS repo has no dbgen tree. Pinned to a commit for
# reproducibility; override DBGEN_REPO/DBGEN_COMMIT to use a fork or newer pin.
DBGEN_REPO="${DBGEN_REPO:-https://github.com/electrum/tpch-dbgen}"
DBGEN_COMMIT="${DBGEN_COMMIT:-32f1c1b92d1664dba542e927d23d86ffa57aa253}"

# Look the port up rather than hard-coding it: pg_createcluster hands out the
# next free port, so which version got which port depends on install order.
PORT="$(pg_lsclusters -h | awk -v v="$PGVER" '$1 == v && $2 == "main" { print $3 }')"
if [ -z "$PORT" ]; then
    echo "No 'main' cluster for PostgreSQL $PGVER. Installed clusters:" >&2
    pg_lsclusters >&2
    exit 1
fi
echo "==> [$DB] target: PostgreSQL $PGVER on port $PORT"

pg() { sudo -u "$PGUSER" psql -p "$PORT" -v ON_ERROR_STOP=1 "$@"; }

# Fetch the dbgen SOURCE if it is not already on disk, so the tree need not be
# committed to git. An existing checkout (source present) is left untouched.
ensure_dbgen_source() {
    if [ -f "$DBGEN_DIR/build.c" ] || [ -f "$DBGEN_DIR/dbgen.c" ]; then
        return 0
    fi
    echo "==> tpch-dbgen source not found - cloning $DBGEN_REPO @ $DBGEN_COMMIT"
    command -v git >/dev/null 2>&1 || { echo "git is required to fetch tpch-dbgen" >&2; exit 1; }
    rm -rf "$DBGEN_DIR"
    git clone --quiet "$DBGEN_REPO" "$DBGEN_DIR" \
        || { echo "failed to clone $DBGEN_REPO" >&2; exit 1; }
    if ! git -C "$DBGEN_DIR" checkout --quiet "$DBGEN_COMMIT" 2>/dev/null; then
        echo "    warning: pinned commit not found; using the default branch instead" >&2
    fi
}

# The upstream ships makefile.suite (a template) with no ready-to-use makefile.
# Generate one with the config that builds a working dbgen here, unless a
# configured makefile is already present (existing checkouts keep theirs).
ensure_dbgen_makefile() {
    [ -f "$DBGEN_DIR/makefile" ] && return 0
    [ -f "$DBGEN_DIR/makefile.suite" ] || { echo "no makefile(.suite) in $DBGEN_DIR" >&2; exit 1; }
    echo "==> generating tpch-dbgen/makefile (CC=gcc DATABASE=ORACLE MACHINE=LINUX WORKLOAD=TPCH)"
    sed -e 's/^CC *=.*/CC       = gcc/' \
        -e 's/^DATABASE *=.*/DATABASE = ORACLE/' \
        -e 's/^MACHINE *=.*/MACHINE  = LINUX/' \
        -e 's/^WORKLOAD *=.*/WORKLOAD = TPCH/' \
        "$DBGEN_DIR/makefile.suite" > "$DBGEN_DIR/makefile"
}

# Loading the SAME scale factor into several clusters would otherwise re-run
# dbgen once per cluster. SKIP_DBGEN=1 reuses the .tbl files already on disk and
# KEEP_TBL=1 leaves them there afterwards, so a caller can generate once and
# load many times. Defaults keep the old behaviour: generate, load, clean up.
if [ "${SKIP_DBGEN:-0}" = "1" ] && [ -s "$DBGEN_DIR/lineitem.tbl" ]; then
    echo "==> [$DB] reusing the existing .tbl files (SKIP_DBGEN=1)"
else
    # tpch-dbgen is not committed (see .gitignore); fetch the source if missing,
    # then build the dbgen binary once (a fresh clone has no binary).
    ensure_dbgen_source
    if [ ! -x "$DBGEN_DIR/dbgen" ]; then
        echo "==> [$DB] no dbgen binary - building it from source"
        ensure_dbgen_makefile
        make -C "$DBGEN_DIR" dbgen
    fi
    echo "==> [$DB] generating TPC-H data at scale factor $SF (this can take a while)"
    ( cd "$DBGEN_DIR" && ./dbgen -f -s "$SF" )   # -f: overwrite without prompting
fi

echo "==> [$DB] (re)creating database"
pg -d postgres -c "DROP DATABASE IF EXISTS $DB;"
pg -d postgres -c "CREATE DATABASE $DB;"

echo "==> [$DB] applying schema"
pg -d "$DB" -f "$SCHEMA"

echo "==> [$DB] loading tables (streamed; trailing '|' stripped on the fly)"
for t in $TABLES; do
    t0=$(date +%s)
    sed 's/|$//' "$DBGEN_DIR/$t.tbl" \
        | pg -d "$DB" -c "\copy $t FROM STDIN WITH (FORMAT csv, DELIMITER '|')"
    echo "    - $t loaded ($(($(date +%s) - t0))s)"
done

echo "==> [$DB] creating indexes + get_tax_rate()"
pg -d "$DB" <<'SQL'
CREATE INDEX idx_lineitem_order  ON lineitem(l_orderkey);
CREATE INDEX idx_orders_cust     ON orders(o_custkey);
CREATE INDEX idx_customer_nation ON customer(c_nationkey);
CREATE OR REPLACE FUNCTION get_tax_rate() RETURNS numeric LANGUAGE plpgsql AS $$
BEGIN RETURN 0.07; END;
$$;
SQL

echo "==> [$DB] ANALYZE"
pg -d "$DB" -c "ANALYZE;"

if [ "${KEEP_TBL:-0}" = "1" ]; then
    echo "==> [$DB] keeping the .tbl files for the next cluster (KEEP_TBL=1)"
else
    echo "==> [$DB] removing generated .tbl files to reclaim disk"
    rm -f "$DBGEN_DIR"/*.tbl
fi

echo "==> [$DB] DONE. database size:"
pg -d "$DB" -tAc "SELECT pg_size_pretty(pg_database_size('$DB'));"
