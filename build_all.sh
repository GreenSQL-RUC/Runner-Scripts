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
# After the base DBs, it also builds the INDEXED CLONES (<db>_idx, via
# build_tpch_indexed.sh) BY DEFAULT, since the parameter sweeps default to
# DBS="tpch tpch_idx". Set SKIP_INDEX=1 to build only the base DBs.
#
# Databases that already exist are SKIPPED, so this is safe to re-run after
# adding a version or a scale factor. FORCE=1 rebuilds them instead.
#
# FRESH UBUNTU (24.04): works out of the box. Prerequisites - the build toolchain
# and the requested PostgreSQL majors (via the PGDG apt repo, each with its own
# 'main' cluster) - are installed first by bootstrap_ubuntu.sh, so the matrix
# below finds every cluster. Set SKIP_BOOTSTRAP=1 on a box you already manage.
#
# Run as root so the inner "sudo -u postgres" needs no password:
#   sudo bash build_all.sh
#   sudo bash build_all.sh "2" "14 18"
#   sudo FORCE=1 bash build_all.sh "1" "16"
#   sudo SKIP_BOOTSTRAP=1 bash build_all.sh          # skip prerequisite install
#
set -euo pipefail

SFS="${1:-1 2 5}"
VERS="${2:-14 16 18}"

HERE="$(cd "$(dirname "$0")" && pwd)"

# Fresh-box provisioning: install the toolchain and the requested PostgreSQL
# majors up front (idempotent), so every cluster the matrix needs exists.
if [ "${SKIP_BOOTSTRAP:-0}" != "1" ] && [ -f "$HERE/bootstrap_ubuntu.sh" ]; then
    bash "$HERE/bootstrap_ubuntu.sh" $VERS
fi

port_of() {
    command -v pg_lsclusters >/dev/null 2>&1 || return 0
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

# Build the indexed clones (<db>_idx) by default - the parameter sweeps default to
# DBS="tpch tpch_idx", so the _idx DBs are part of a normal build. Each base DB
# just built gets an _idx TEMPLATE clone + the ixtest_ index suite. Set
# SKIP_INDEX=1 to build only the base DBs. FORCE is passed through so a forced
# base rebuild also rebuilds its _idx.
if [ "${SKIP_INDEX:-0}" != "1" ]; then
    idx_dbs=""
    for sf in $SFS; do
        if [ "$sf" = "1" ]; then idx_dbs="$idx_dbs tpch"; else idx_dbs="$idx_dbs tpch$sf"; fi
    done
    echo
    echo "===================== INDEXED CLONES ====================="
    FORCE="${FORCE:-0}" bash "$HERE/build_tpch_indexed.sh" "$idx_dbs" "$VERS"
fi

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
