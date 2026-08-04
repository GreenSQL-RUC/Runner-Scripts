#!/usr/bin/env bash
#
# build_all.sh [scale_factors] [pg_versions]
#
# Builds the whole benchmark matrix: every scale factor on every installed
# PostgreSQL cluster. Data is generated ONCE per scale factor and loaded into
# each cluster in turn (see SKIP_DBGEN / KEEP_TBL in build_tpch.sh), because
# dbgen at SF5 is far slower than the load itself.
#
# Database naming follows the existing convention: SF1 is "tpch" and every
# other scale factor is "tpch<SF>" - so SF2 -> tpch2, SF5 -> tpch5. The same
# names exist on all clusters; the port selects which one you reach.
#
# Databases that already exist are SKIPPED, so this is safe to re-run after
# adding a version or a scale factor. FORCE=1 rebuilds them instead.
#
# Run as root so the inner "sudo -u postgres" needs no password:
#   sudo bash build_all.sh
#   sudo bash build_all.sh "2" "14 18"
#   sudo FORCE=1 bash build_all.sh "1" "16"
#
set -euo pipefail

SFS="${1:-1 2 5}"
VERS="${2:-14 16 18}"

HERE="$(cd "$(dirname "$0")" && pwd)"

port_of() {
    pg_lsclusters -h | awk -v v="$1" '$1 == v && $2 == "main" { print $3 }'
}

db_exists() {
    local port="$1" db="$2"
    [ "$(sudo -u postgres psql -p "$port" -d postgres -tAc \
         "SELECT 1 FROM pg_database WHERE datname = '$db';" 2>/dev/null)" = "1" ]
}

for sf in $SFS; do
    # SF1 keeps the bare name "tpch" so existing logs and defaults still resolve.
    if [ "$sf" = "1" ]; then db="tpch"; else db="tpch$sf"; fi

    # Work out which clusters actually need this scale factor before generating
    # anything - dbgen is the expensive step and is pointless if all are built.
    todo=""
    for ver in $VERS; do
        port="$(port_of "$ver")"
        if [ -z "$port" ]; then
            echo "!! no 'main' cluster for PostgreSQL $ver, skipping" >&2
            continue
        fi
        if [ "${FORCE:-0}" != "1" ] && db_exists "$port" "$db"; then
            echo "== $db already exists on PostgreSQL $ver (port $port), skipping"
        else
            todo="$todo $ver"
        fi
    done

    if [ -z "$todo" ]; then
        echo "== scale factor $sf: nothing to do"
        continue
    fi

    first=1
    for ver in $todo; do
        if [ "$first" = "1" ]; then
            # Generate the data on the first cluster of this scale factor...
            SKIP_DBGEN=0 KEEP_TBL=1 bash "$HERE/build_tpch.sh" "$sf" "$db" "$ver"
            first=0
        else
            # ...and reuse it for the rest.
            SKIP_DBGEN=1 KEEP_TBL=1 bash "$HERE/build_tpch.sh" "$sf" "$db" "$ver"
        fi
    done

    echo "==> scale factor $sf done on:$todo - dropping its .tbl files"
    rm -f "$HERE/tpch-dbgen"/*.tbl
done

echo
echo "===================== MATRIX ====================="
for ver in $VERS; do
    port="$(port_of "$ver")"
    [ -z "$port" ] && continue
    echo "-- PostgreSQL $ver (port $port)"
    sudo -u postgres psql -p "$port" -d postgres -tAc \
        "SELECT '   ' || rpad(datname, 12) || pg_size_pretty(pg_database_size(datname))
           FROM pg_database WHERE datname LIKE 'tpch%' ORDER BY datname;"
done
