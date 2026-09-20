#!/usr/bin/env bash
#
# fetch_sqlstorm_queries.sh
#
# Fetch the SQLStorm TPC-H query set (~17k .sql files) from
#   https://github.com/SQL-Storm/SQLStorm/tree/master/v1.0/tpch/queries
# into queries/tpch/SQLStorm/ next to this script (i.e. inside GreenSQL,
# wherever the repo lives), so it works no matter which directory you run it
# from.
#
# Only that one folder is downloaded: a shallow, blob-filtered, sparse git
# checkout of the upstream repo goes into a temporary directory, the .sql files
# are copied out, and the temporary clone is removed. Pinned to a commit for
# reproducibility; override SQLSTORM_REPO / SQLSTORM_COMMIT to use a fork or a
# newer pin, or SQLSTORM_DEST to put the files elsewhere.
#
# The upstream files are bare SELECT/WITH statements. Every query in this repo
# is written as "EXPLAIN (ANALYZE, ...) <statement>" so query_runner can parse
# the server-side figures (planning/execution ms, buffers, rows) back out of
# psql's output - without the wrapper those sample columns come back empty. So
# each file is copied with the same EXPLAIN line the generators use prepended,
# plus a provenance comment. A few upstream files lack a terminating ';' (psql
# -f silently drops an unterminated final statement), so one is appended when
# the last non-comment line does not end in ';'.
#
# The script is idempotent: if the destination already has .sql files it does
# nothing unless FORCE=1 is set, in which case the destination is wiped and
# re-fetched.
#
#   bash fetch_sqlstorm_queries.sh            # fetch (no-op if already present)
#   FORCE=1 bash fetch_sqlstorm_queries.sh    # wipe and re-fetch
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"          # repo root (this script lives in build/)

SQLSTORM_REPO="${SQLSTORM_REPO:-https://github.com/SQL-Storm/SQLStorm}"
SQLSTORM_COMMIT="${SQLSTORM_COMMIT:-b3bb0b96794a6afe9bb8f3ff2b243562b779c40d}"
SQLSTORM_SUBDIR="v1.0/tpch/queries"
DEST="${SQLSTORM_DEST:-$ROOT/queries/tpch/SQLStorm}"

command -v git >/dev/null 2>&1 || { echo "git is required to fetch the SQLStorm queries" >&2; exit 1; }

# Skip when already populated (unless FORCE=1), so build scripts can call this
# unconditionally without re-downloading 17k files every time.
existing=$(find "$DEST" -maxdepth 1 -name '*.sql' 2>/dev/null | wc -l)
if [ "$existing" -gt 0 ] && [ "${FORCE:-0}" != "1" ]; then
    echo "==> $DEST already holds $existing .sql files - nothing to do (FORCE=1 to re-fetch)"
    exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sqlstorm.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "==> cloning $SQLSTORM_REPO (sparse: $SQLSTORM_SUBDIR only)"
git clone --quiet --depth 1 --filter=blob:none --sparse "$SQLSTORM_REPO" "$TMP/repo" \
    || { echo "failed to clone $SQLSTORM_REPO" >&2; exit 1; }
git -C "$TMP/repo" sparse-checkout set --no-cone "$SQLSTORM_SUBDIR"

# Pin to the known commit so everyone gets the same query set. A shallow clone
# only has the tip, so fetch the pinned commit explicitly if it is not the tip.
if [ "$(git -C "$TMP/repo" rev-parse HEAD)" != "$SQLSTORM_COMMIT" ]; then
    if git -C "$TMP/repo" fetch --quiet --depth 1 origin "$SQLSTORM_COMMIT" 2>/dev/null \
       && git -C "$TMP/repo" checkout --quiet "$SQLSTORM_COMMIT" 2>/dev/null; then
        :
    else
        echo "    warning: pinned commit $SQLSTORM_COMMIT not found; using the default branch tip instead" >&2
    fi
fi

SRC="$TMP/repo/$SQLSTORM_SUBDIR"
[ -d "$SRC" ] || { echo "upstream folder $SQLSTORM_SUBDIR not found in the clone" >&2; exit 1; }

UPSTREAM_SHORT="$(git -C "$TMP/repo" rev-parse --short HEAD)"
echo "==> copying .sql files into $DEST (prepending the EXPLAIN wrapper)"
rm -rf "$DEST"
mkdir -p "$DEST"
# One awk pass over every file: emit the provenance comment + EXPLAIN line at the
# top of each, pass the body through untouched, and append ';' if the last
# meaningful line (non-blank, not a comment, trailing "-- ..." stripped) does not
# already end in one. Files are processed in a single process, so 17k files take
# seconds rather than minutes.
find "$SRC" -maxdepth 1 -name '*.sql' -print0 | sort -z | xargs -0 awk \
    -v dest="$DEST" -v subdir="$SQLSTORM_SUBDIR" -v commit="$UPSTREAM_SHORT" '
    function finish() {
        if (out == "") return
        if (last != "" && substr(last, length(last), 1) != ";") print ";" > out
        close(out)
    }
    FNR == 1 {
        finish()
        n = split(FILENAME, parts, "/"); base = parts[n]
        out = dest "/" base; last = ""
        print "-- SQLStorm " subdir "/" base " @ " commit " (EXPLAIN wrapper added by fetch_sqlstorm_queries.sh)" > out
        print "EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)" > out
    }
    {
        print > out
        line = $0; sub(/--.*$/, "", line); gsub(/[ \t\r]+$/, "", line)
        if (line ~ /[^ \t]/) last = line
    }
    END { finish() }'

count=$(find "$DEST" -maxdepth 1 -name '*.sql' | wc -l)
echo "==> done: $count .sql files in $DEST (upstream commit $UPSTREAM_SHORT)"
