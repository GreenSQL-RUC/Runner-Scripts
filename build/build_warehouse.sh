#!/usr/bin/env bash
#
# build_warehouse.sh <csv_path> 

# Load real-world warehouse/retail sales data (Data/export.csv) into a fresh <db_name>, 
# normalized into suppliers, items, and sales tables. This is adapted from build_tpch.sh: 
# no dbgen, no scale factor, and PORT is passed directly rather than a lookup by 
# pg_lclusters (when initially added)

# Run as root so the inner "sudo -u postgres" needs no password. The 3rd arg is
# the PostgreSQL MAJOR VERSION (default 16); the port is looked up from it, so
# this stays correct across machines (pg_createcluster assigns ports by install
# order).
#   sudo bash build_warehouse.sh warehouse Data/export.csv        # PG16
#   sudo bash build_warehouse.sh warehouse Data/export.csv 18     # PG18

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



# PUT THIS BACK IN FOR LAPTOP at 44
# SF="${1:?usage: build_tpch.sh <scale_factor> <db_name> [pg_version]}"
# DB="${2:?usage: build_tpch.sh <scale_factor> <db_name> [pg_version]}"
# PGVER="${3:-16}"

#PUT THIS BACK IN FOR LAPTOP AT 49
##DBGEN_DIR="$ROOT/tpch-dbgen"

set -euo pipefail

DB="${1:?usage: build_warehouse.sh <db_name> <csv_path> [pg_version]}"
CSV="${2:?usage: build_warehouse.sh <db_name> <csv_path> [pg_version]}"
CSV="$(realpath "$CSV")"
PGVER="${3:-16}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"          # repo root (this script lives in build/)

SCHEMA="$ROOT/schema/warehouse_schema.sql"
PGUSER=postgres

# Look the port up from the version rather than hard-coding it: pg_createcluster
# hands out ports in install order, so which version got which port is
# machine-specific (here PG16=5432, but not necessarily elsewhere).
PORT="$(pg_lsclusters -h | awk -v v="$PGVER" '$1 == v && $2 == "main" { print $3 }')"
if [ -z "$PORT" ]; then
    echo "No 'main' cluster for PostgreSQL $PGVER. Installed clusters:" >&2
    pg_lsclusters >&2
    exit 1
fi

if [ ! -f "$CSV" ]; then
    echo "CSV not found: $CSV" >&2
    exit 1

fi 

echo "==> [$DB] target: PostgreSQL $PGVER on port $PORT"

pg() { sudo -u "$PGUSER" psql -p "$PORT" -v ON_ERROR_STOP=1 "$@"; }

echo "==> [$DB] (re)creating database"
pg -d postgres -c "DROP DATABASE IF EXISTS $DB;"
pg -d postgres -c "CREATE DATABASE $DB;"

echo "==> [$DB] applying schema"
pg -d "$DB" -f "$SCHEMA"

echo "==> [DB] loading raw csv into staging"
t0=$(date +%s)
pg -d "$DB" -c "\copy staging_sales FROM '$CSV' WITH (FORMAT csv, HEADER true)"
echo "  - staging loaded ($(($(date +%s) - t0))s)"

echo "==> [$DB] populating normalized tables"
pg -d "$DB" << 'SQL'

INSERT INTO suppliers (supplier_name)
SELECT DISTINCT supplier FROM staging_sales WHERE supplier IS NOT NULL;

INSERT INTO items (item_code, item_description, item_type)
SELECT DISTINCT item_code, item_description, item_type FROM staging_sales;


INSERT INTO sales (sale_year, sale_month, supplier_id, item_id, retail_sales, retail_transfers, warehouse_sales)
SELECT s.sale_year, s.sale_month, sup.supplier_id, i.item_id,
       CASE WHEN s.retail_sales LIKE '(%)' THEN REPLACE('-' || trim(s.retail_sales, '()'), ',', '')::numeric ELSE REPLACE(s.retail_sales, ',', '')::numeric END,
       CASE WHEN s.retail_transfers LIKE '(%)' THEN REPLACE('-' || trim(s.retail_transfers, '()'), ',', '')::numeric ELSE REPLACE(s.retail_transfers, ',', '')::numeric END,
       CASE WHEN s.warehouse_sales LIKE '(%)' THEN REPLACE('-' || trim(s.warehouse_sales, '()'), ',', '')::numeric ELSE REPLACE(s.warehouse_sales, ',', '')::numeric END
FROM staging_sales s
JOIN suppliers sup ON sup.supplier_name = s.supplier
JOIN items i ON i.item_code = s.item_code
            AND i.item_description IS NOT DISTINCT FROM s.item_description
            AND i.item_type IS NOT DISTINCT FROM s.item_type;
SQL

echo "==> [$DB] dropping staging table"
pg -d "$DB" -c "DROP TABLE staging_sales;"

echo "==> [$DB] DONE. database size:"
pg -d "$DB" -tAc "SELECT pg_size_pretty(pg_database_size('$DB'));"
