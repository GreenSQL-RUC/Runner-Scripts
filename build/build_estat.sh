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
#   sudo bash build_estat.sh estat Data/estat_nama_10_a64_p5.csv        # PG16
#   sudo bash build_estat.sh estat Data/estat_nama_10_a64_p5.csv 18     # PG18

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

DB="${1:?usage: build_estat.sh <db_name> <csv_path> [pg_version]}"
CSV="${2:?usage: build_estat.sh <db_name> <csv_path> [pg_version]}"
CSV="$(realpath "$CSV")"
PGVER="${3:-16}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"          # repo root (this script lives in build/)

SCHEMA="$ROOT/schema/estat_schema.sql"
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

echo "==> [$DB] creating staging table"

{
cat <<'SQL'
CREATE TABLE staging_capital_stock (
    freq TEXT,
    unit TEXT,
    nace_r2 TEXT,
    asset10 TEXT,
    na_item TEXT,
    geo TEXT,
SQL

for y in $(seq 1975 2025); do
    if [ "$y" -eq 2025 ]; then
        echo " y${y} TEXT"
    else
        echo " y${y} TEXT,"
    fi
done

echo ");"
} > /tmp/create_staging.sql

pg -d "$DB" -f /tmp/create_staging.sql

echo "==> [$DB] fixing header row"
HEADER_TMP=/tmp/estat_header_fix.csv

CSV="$CSV" DST="$HEADER_TMP" python3 <<'PY'
import csv, os

src = os.environ["CSV"]
dst = os.environ["DST"]

with open(src, newline='', encoding='utf-8') as f:
    reader = csv.reader(f)
    rows = list(reader)

header = rows[0]
header[5] = "geo"
for i in range(6, len(header)):
    header[i] = "y" + header[i].strip()

with open(dst, "w", newline='', encoding='utf-8') as f:
    writer = csv.writer(f)
    writer.writerow(header)
    writer.writerows(rows[1:])
PY

echo "==> [$DB] loading raw csv into staging"
t0=$(date +%s)
pg -d "$DB" -c "\copy staging_capital_stock FROM '$HEADER_TMP' CSV HEADER"
echo "    - staging loaded ($(($(date +%s) - t0))s)"  

echo "==> [$DB] populating dimensions"
pg -d "$DB" <<'SQL'

INSERT INTO dim_geo (geo_code) 
SELECT DISTINCT geo FROM staging_capital_stock WHERE geo IS NOT NULL;

INSERT INTO dim_unit (unit_code)
SELECT DISTINCT unit FROM staging_capital_stock WHERE unit IS NOT NULL;

INSERT INTO dim_nace (nace_code)
SELECT DISTINCT nace_r2 FROM staging_capital_stock WHERE nace_r2 IS NOT NULL;

INSERT INTO dim_asset (asset_code)
SELECT DISTINCT asset10 FROM staging_capital_stock WHERE asset10 IS NOT NULL;

INSERT INTO dim_na_item (na_item_code)
SELECT DISTINCT na_item FROM staging_capital_stock WHERE na_item IS NOT NULL;
SQL

echo "==> [$DB] generating unpivot SQL"
{
cat <<'SQL'
INSERT INTO fact_capital_stock
(year, geo_id, unit_id, nace_id, asset_id, na_item_id, value, flag)
SELECT
    v.year,
    g.geo_id,
    u.unit_id,
    n.nace_id,
    a.asset_id,
    ni.na_item_id,

    CASE
        WHEN trim(v.raw_value) = ':' THEN NULL
        ELSE NULLIF(regexp_replace(v.raw_value, '[^0-9\.-]', '', 'g'), '')::numeric
    END AS value,

    NULLIF(regexp_replace(trim(v.raw_value), '[0-9\.\-: ]', '', 'g'), '') AS flag

FROM staging_capital_stock s
JOIN dim_geo g ON g.geo_code = s.geo
JOIN dim_unit u ON u.unit_code = s.unit
JOIN dim_nace n ON n.nace_code = s.nace_r2
JOIN dim_asset a ON a.asset_code = s.asset10
JOIN dim_na_item ni ON ni.na_item_code = s.na_item
CROSS JOIN LATERAL (
VALUES
SQL

first=1
for y in $(seq 1975 2025); do
    if [ $first -eq 1 ]; then
        first=0
        echo " ($y, s.y${y})"
    else
        echo " , ($y, s.y${y})"
    fi
done

cat <<'SQL'
) AS v(year, raw_value)
WHERE trim(v.raw_value) <> ':';
SQL
} > /tmp/load_fact.sql

echo "==> [$DB] loading fact table"
t1=$(date +%s)
pg -d "$DB" -f /tmp/load_fact.sql
echo "    - fact table loaded ($(($(date +%s) - t1))s)"

echo "==> [$DB] dropping staging table"
pg -d "$DB" -c "DROP TABLE staging_capital_stock;"

echo "==> [$DB] done"
pg -d "$DB" -tAc "SELECT pg_size_pretty(pg_database_size('$DB'));"