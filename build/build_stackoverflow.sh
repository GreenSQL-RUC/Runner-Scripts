#!/usr/bin/env bash
#
# build_stackoverflow.sh [size] [db_name] [pg_version]
#
# Build the StackOverflow database that the SQLStorm v1.0 stackoverflow queries
# run against, plus that query set. Three sizes are published by the SQLStorm
# authors (https://github.com/SQL-Storm/SQLStorm, "Running SQLStorm without
# OLAPBench"); each is a tar.gz of one headerless CSV per table:
#
#   size    archive                     download  site              default db
#   1gb     stackoverflow_dba.tar.gz    0.4 GB    dba.stackexchange stackoverflow_1gb   (default)
#   12gb    stackoverflow_math.tar.gz   4.5 GB    math.stackexchange stackoverflow_12gb
#   222gb   stackoverflow.tar.gz       84 GB      stackoverflow.com stackoverflow_222gb
#
# Steps:
#   1. queries: fetch_sqlstorm_queries.sh with SQLSTORM_DATASET=stackoverflow
#      -> queries/stackoverflow/SQLStorm/. Upstream flags ~5.7k of the ~18k
#      queries as invalid (valid_queries.csv / invalid_queries.csv); only the
#      valid ones PostgreSQL agreed on are copied (see that script).
#   2. download the archive into Data/stackoverflow/ (resumable, size-checked
#      against the server, skipped when already complete). Kept afterwards so
#      other clusters can load it without downloading again; KEEP_ARCHIVE=0
#      deletes it after a successful load.
#   3. create <db> with schema/stackoverflow_schema_nofk.sql, the upstream
#      schema WITHOUT foreign keys (the one to use: tables load in any order,
#      no FK checks during the load, and no FK-based join estimates in plans).
#   4. load: the archive is streamed through tar ONCE and each CSV member is
#      piped (named pipe) straight into a server-side COPY, so the CSVs never
#      land on disk (the 222 GB set
#      would not fit twice). Primary keys are dropped for the load and re-added
#      afterwards, which is much faster than maintaining them row by row and
#      still checks the ids are unique.
#   5. VACUUM (FREEZE, ANALYZE): statistics, plus the hint bits and visibility
#      map written now, so the first measured queries do not pay for them.
#
# An existing <db> is left alone (FORCE=1 drops and rebuilds it). Before
# downloading or loading, free space is checked against what the size needs
# (SKIP_DISK_CHECK=1 to override).
#
# Run as root (sudo) so "sudo -u postgres" needs no password; files in the repo
# (queries, the archive) are written as the invoking user, not root:
#   sudo bash build/build_stackoverflow.sh                     # 1gb -> stackoverflow_1gb on PG 18
#   sudo bash build/build_stackoverflow.sh 12gb                # the math.stackexchange set
#   sudo bash build/build_stackoverflow.sh 222gb so_full 17    # full set, own name, PG 17
#   make build-stackoverflow [SO_SIZE=12gb] [SO_DB=...] [PGVER=18]
#
# ENV: FORCE=1 (rebuild an existing db)  KEEP_ARCHIVE=0 (delete the archive after
#      loading)  DOWNLOAD_ONLY=1 (stop after the download)  SKIP_QUERIES=1
#      SKIP_DISK_CHECK=1  SKIP_BOOTSTRAP=1 (as build_tpch.sh)  SO_DATA_DIR=<dir>
#
# The data is Stack Exchange content under CC BY-SA 4.0 (license.txt in the
# archive); it is downloaded on demand and git-ignored, never committed.
#
set -euo pipefail

# Loader mode: tar re-runs this script once per archive member with the
# member's bytes on stdin and its path in TAR_FILENAME (a plain bash function
# would not survive tar's /bin/sh). Non-CSV members (license.txt) are drained.
#
# The bytes go through a named pipe that the SERVER reads with COPY ... FROM
# '<fifo>', not through psql's "\copy ... FROM STDIN": psql ends STDIN data at
# any line that is exactly "\.", even inside a quoted multi-line field, and
# post bodies contain such lines. The server's CSV parser tracks quotes (this is
# how upstream's copy.sql loads too), and a pipe keeps it one pass with nothing
# written to disk.
load_member() {
    local base="${TAR_FILENAME##*/}" table fifo out cat_pid t0=$SECONDS
    case "$base" in
        *.csv) table="${base%.csv}"; table="${table,,}" ;;
        *) cat > /dev/null; return 0 ;;
    esac
    case " $SO_TABLES " in
        *" $table "*) ;;
        *) echo "!! $base: not a table of the schema" >&2; cat > /dev/null; return 1 ;;
    esac
    fifo="$SO_TMP/$table.pipe"
    mkfifo -m 644 "$fifo"
    # A background job gets /dev/null as stdin, so hand it the member via fd 3.
    exec 3<&0
    cat <&3 > "$fifo" &
    cat_pid=$!
    if ! out=$(sudo -u postgres psql -p "$SO_PORT" -d "$SO_DB" -v ON_ERROR_STOP=1 \
               -c "COPY $table FROM '$fifo' WITH (FORMAT csv, DELIMITER ',', NULL '')" 2>&1); then
        kill "$cat_pid" 2>/dev/null
        echo "!! $table: $out" >&2
        return 1
    fi
    wait "$cat_pid"
    rm -f "$fifo"
    case "$out" in
        "COPY 0") echo "!! $table: no rows loaded" >&2; return 1 ;;
        COPY\ *) ;;
        *) echo "!! $table: unexpected psql output: $out" >&2; return 1 ;;
    esac
    echo "$table ${out#COPY }" >> "$SO_TMP/loaded.txt"
    printf '    - %-17s %12s rows  (%ss)\n' "$table" "${out#COPY }" "$(( SECONDS - t0 ))"
}
if [ "${1:-}" = "--load-member" ]; then
    load_member
    exit
fi

SIZE_ARG="${1:-1gb}"
case "${SIZE_ARG,,}" in
    1|1gb|dba)        SIZE=1gb;   ARCHIVE=stackoverflow_dba.tar.gz ;;
    12|12gb|math)     SIZE=12gb;  ARCHIVE=stackoverflow_math.tar.gz ;;
    222|222gb|full)   SIZE=222gb; ARCHIVE=stackoverflow.tar.gz ;;
    *) echo "usage: build_stackoverflow.sh [1gb|12gb|222gb] [db_name] [pg_version]" >&2; exit 2 ;;
esac
DB="${2:-stackoverflow_$SIZE}"
PGVER="${3:-18}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"          # repo root (this script lives in build/)
SCHEMA="$ROOT/schema/stackoverflow_schema_nofk.sql"
DATA_DIR="${SO_DATA_DIR:-$ROOT/Data/stackoverflow}"
URL="${SO_BASE_URL:-https://db.in.tum.de/~schmidt/data}/$ARCHIVE"
PGUSER=postgres
TABLES="posthistorytypes linktypes posttypes closereasontypes votetypes users badges posts comments posthistory postlinks tags votes"

# Space needed, in GB: the archive, and the loaded database. The 1gb set loads
# to 1.2 GB (0.86x its 1.36 GB of CSV; the archives compress ~3.4x); the larger
# sets are scaled from that, with margin.
case "$SIZE" in
    1gb)   NEED_ARCHIVE_GB=1;   NEED_DB_GB=3 ;;
    12gb)  NEED_ARCHIVE_GB=5;   NEED_DB_GB=20 ;;
    222gb) NEED_ARCHIVE_GB=85;  NEED_DB_GB=300 ;;
esac

[ -f "$SCHEMA" ] || { echo "schema not found: $SCHEMA" >&2; exit 1; }

# Files inside the repo are created as the user who ran sudo, so a root build
# does not leave root-owned queries or archives behind.
as_user() {
    if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        sudo -u "$SUDO_USER" "$@"
    else
        "$@"
    fi
}

# Same cluster lookup / provisioning as build_tpch.sh.
find_port() {
    command -v pg_lsclusters >/dev/null 2>&1 || return 0
    pg_lsclusters -h | awk -v v="$1" '$1 == v && $2 == "main" { print $3 }'
}
PORT="$(find_port "$PGVER")"
if [ -z "$PORT" ] && [ "${SKIP_BOOTSTRAP:-0}" != "1" ] \
   && [ "$(id -u)" = 0 ] && [ -f "$HERE/bootstrap_ubuntu.sh" ]; then
    echo "==> no PostgreSQL $PGVER 'main' cluster - provisioning it (bootstrap_ubuntu.sh $PGVER)"
    bash "$HERE/bootstrap_ubuntu.sh" "$PGVER"
    PORT="$(find_port "$PGVER")"
fi
[ -n "$PORT" ] || { echo "No 'main' cluster for PostgreSQL $PGVER." >&2; exit 1; }
echo "==> [$DB] StackOverflow $SIZE on PostgreSQL $PGVER (port $PORT)"

pg() { sudo -u "$PGUSER" psql -p "$PORT" -v ON_ERROR_STOP=1 "$@"; }

# ---- 1. queries (cheap; fails early on a network problem) -------------------
if [ "${SKIP_QUERIES:-0}" != "1" ]; then
    as_user env SQLSTORM_DATASET=stackoverflow bash "$HERE/fetch_sqlstorm_queries.sh"
fi

db_exists=$(pg -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB';")
if [ "$db_exists" = 1 ] && [ "${FORCE:-0}" != "1" ] && [ "${DOWNLOAD_ONLY:-0}" != "1" ]; then
    echo "==> [$DB] already exists - nothing to load (FORCE=1 to rebuild)"
    exit 0
fi

# ---- disk check ---------------------------------------------------------------
as_user mkdir -p "$DATA_DIR"
ARCHIVE_PATH="$DATA_DIR/$ARCHIVE"
remote_bytes=$(curl -sIL --max-time 30 "$URL" | tr -d '\r' \
               | awk 'tolower($1) == "content-length:" { v = $2 } END { print v + 0 }')
local_bytes=$(stat -c %s "$ARCHIVE_PATH" 2>/dev/null || echo 0)
have_archive=0
if [ "$remote_bytes" -gt 0 ] && [ "$local_bytes" = "$remote_bytes" ]; then
    have_archive=1
elif [ "$remote_bytes" = 0 ] && [ "$local_bytes" -gt 0 ]; then
    echo "    warning: cannot reach $URL to check the size; using the local archive as is" >&2
    have_archive=1
fi

avail_gb() { df -P -BG "$1" | awk 'NR == 2 { sub(/G$/, "", $4); print $4 }'; }
if [ "${SKIP_DISK_CHECK:-0}" != "1" ]; then
    pgdata=$(pg -d postgres -tAc "SHOW data_directory;")
    need_a=$(( have_archive ? 0 : NEED_ARCHIVE_GB ))
    need_d=$(( ${DOWNLOAD_ONLY:-0} == 1 ? 0 : NEED_DB_GB ))
    if [ "$(stat -c %d "$DATA_DIR")" = "$(stat -c %d "$pgdata")" ]; then
        checks=("$DATA_DIR:$(( need_a + need_d ))")
    else
        checks=("$DATA_DIR:$need_a" "$pgdata:$need_d")
    fi
    for c in "${checks[@]}"; do
        dir="${c%:*}"; need="${c##*:}"; free=$(avail_gb "$dir")
        if [ "$need" -gt "$free" ]; then
            echo "!! not enough space on $(df -P "$dir" | awk 'NR == 2 { print $6 }'): ${free} GB free, ~${need} GB needed for the $SIZE set" >&2
            echo "   (move SO_DATA_DIR elsewhere, free space, or SKIP_DISK_CHECK=1 to try anyway)" >&2
            exit 1
        fi
    done
fi

# ---- 2. download ----------------------------------------------------------------
if [ "$have_archive" = 1 ]; then
    echo "==> [$DB] archive already downloaded: $ARCHIVE_PATH ($(du -h "$ARCHIVE_PATH" | cut -f1))"
else
    echo "==> [$DB] downloading $URL ($(( remote_bytes / 1000000 )) MB) -> $DATA_DIR"
    as_user curl -fL --retry 5 --retry-delay 10 -C - -o "$ARCHIVE_PATH" "$URL"
    local_bytes=$(stat -c %s "$ARCHIVE_PATH")
    if [ "$remote_bytes" -gt 0 ] && [ "$local_bytes" != "$remote_bytes" ]; then
        echo "!! download incomplete: $local_bytes of $remote_bytes bytes (re-run to resume)" >&2
        exit 1
    fi
fi
if [ "${DOWNLOAD_ONLY:-0}" = "1" ]; then
    echo "==> [$DB] DOWNLOAD_ONLY=1: archive is at $ARCHIVE_PATH"
    exit 0
fi

# ---- 3. database + schema ---------------------------------------------------------
echo "==> [$DB] (re)creating database"
pg -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB' AND pid <> pg_backend_pid();" >/dev/null
pg -d postgres -c "DROP DATABASE IF EXISTS $DB;"
pg -d postgres -c "CREATE DATABASE $DB;"
echo "==> [$DB] applying schema (no foreign keys)"
# Streamed on stdin: postgres cannot read files under a 0750 home directory.
pg -d "$DB" -q < "$SCHEMA"

# Primary keys come off for the load and go back on after it.
ADD_PKS=$(pg -d "$DB" -tAc "SELECT format('ALTER TABLE %s ADD CONSTRAINT %I %s;', conrelid::regclass, conname, pg_get_constraintdef(oid))
                             FROM pg_constraint WHERE contype = 'p' AND connamespace = 'public'::regnamespace;")
pg -d "$DB" -tAc "SELECT format('ALTER TABLE %s DROP CONSTRAINT %I;', conrelid::regclass, conname)
                    FROM pg_constraint WHERE contype = 'p' AND connamespace = 'public'::regnamespace;" | pg -d "$DB" -q

# ---- 4. load: one pass over the archive, each CSV member piped into COPY ------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/so_load.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
chmod 755 "$TMP"                   # the server opens the pipes in here

export SO_PORT="$PORT" SO_DB="$DB" SO_TMP="$TMP" SO_TABLES="$TABLES"

if command -v pigz >/dev/null 2>&1; then UNZIP=(-I pigz); else UNZIP=(-z); fi
echo "==> [$DB] loading tables straight from the archive (${UNZIP[*]})"
t0=$SECONDS
tar -x "${UNZIP[@]}" -f "$ARCHIVE_PATH" --to-command="bash '$HERE/build_stackoverflow.sh' --load-member"
missing=""
for t in $TABLES; do
    grep -q "^$t " "$TMP/loaded.txt" 2>/dev/null || missing="$missing $t"
done
[ -z "$missing" ] || { echo "!! [$DB] tables not loaded:$missing" >&2; exit 1; }
echo "    all 13 tables loaded in $(( SECONDS - t0 ))s"

echo "==> [$DB] adding primary keys"
t0=$SECONDS
printf '%s\n' "$ADD_PKS" | pg -d "$DB" -q
echo "    done in $(( SECONDS - t0 ))s"

# ---- 5. freeze + statistics ------------------------------------------------------------
echo "==> [$DB] VACUUM (FREEZE, ANALYZE)"
t0=$SECONDS
pg -d "$DB" -q -c "VACUUM (FREEZE, ANALYZE);"
echo "    done in $(( SECONDS - t0 ))s"

if [ "${KEEP_ARCHIVE:-1}" = "0" ]; then
    echo "==> [$DB] removing the archive (KEEP_ARCHIVE=0)"
    rm -f "$ARCHIVE_PATH"
fi

echo "==> [$DB] DONE: $(pg -d postgres -tAc "SELECT pg_size_pretty(pg_database_size('$DB'));")"
echo "    run the queries with: make run DB_NAME=$DB DIR=queries/stackoverflow/SQLStorm PGVER=$PGVER"
