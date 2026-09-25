#!/usr/bin/env bash
#
# fetch_sqlstorm_queries.sh
#
# Fetch a SQLStorm v1.0 query set from
#   https://github.com/SQL-Storm/SQLStorm/tree/master/v1.0/<dataset>/queries
# into queries/<dataset>/SQLStorm/ inside GreenSQL (wherever the repo lives),
# so it works no matter which directory you run it from.
#
#   SQLSTORM_DATASET=tpch            (default) ~17k queries -> queries/tpch/SQLStorm/
#   SQLSTORM_DATASET=stackoverflow   ~18k upstream, filtered -> queries/stackoverflow/SQLStorm/
#
# QUERY SELECTION (SQLSTORM_QUERY_SET). Upstream classifies every query in
# valid_queries.csv / invalid_queries.csv by comparing the results of
# PostgreSQL, DuckDB and Umbra. The "systems" column lists result groups, the
# first one being the majority (accepted) result.
#   all        every file in queries/ (the TPC-H default, as fetched so far)
#   valid      only queries in valid_queries.csv
#   postgres   valid AND PostgreSQL in the majority group, i.e. PostgreSQL ran
#              it and agreed with the accepted result (the stackoverflow default)
# For a filtered set the decision per upstream file is written next to the
# destination folder as <dest>.selection.csv (query, status, systems).
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
DATASET="${SQLSTORM_DATASET:-tpch}"
SQLSTORM_BASE="v1.0/$DATASET"
SQLSTORM_SUBDIR="$SQLSTORM_BASE/queries"
DEST="${SQLSTORM_DEST:-$ROOT/queries/$DATASET/SQLStorm}"
if [ "$DATASET" = tpch ]; then QUERY_SET="${SQLSTORM_QUERY_SET:-all}"; else QUERY_SET="${SQLSTORM_QUERY_SET:-postgres}"; fi
case "$QUERY_SET" in all|valid|postgres) ;; *) echo "SQLSTORM_QUERY_SET must be all, valid or postgres" >&2; exit 2 ;; esac

command -v git >/dev/null 2>&1 || { echo "git is required to fetch the SQLStorm queries" >&2; exit 1; }

# Skip when already populated (unless FORCE=1), so build scripts can call this
# unconditionally without re-downloading 17k files every time.
existing=0
[ -d "$DEST" ] && existing=$(find "$DEST" -maxdepth 1 -name '*.sql' | wc -l)
if [ "$existing" -gt 0 ] && [ "${FORCE:-0}" != "1" ]; then
    echo "==> $DEST already holds $existing .sql files - nothing to do (FORCE=1 to re-fetch)"
    exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sqlstorm.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "==> cloning $SQLSTORM_REPO (sparse: $SQLSTORM_SUBDIR only)"
git clone --quiet --depth 1 --filter=blob:none --sparse "$SQLSTORM_REPO" "$TMP/repo" \
    || { echo "failed to clone $SQLSTORM_REPO" >&2; exit 1; }
git -C "$TMP/repo" sparse-checkout set --no-cone "$SQLSTORM_SUBDIR" \
    "/$SQLSTORM_BASE/valid_queries.csv" "/$SQLSTORM_BASE/invalid_queries.csv"

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

# The list of files to copy: all of them, or the valid_queries.csv selection.
LIST="$TMP/selected.txt"
if [ "$QUERY_SET" = all ]; then
    find "$SRC" -maxdepth 1 -name '*.sql' -printf '%f\n' | sort > "$LIST"
else
    VALID="$TMP/repo/$SQLSTORM_BASE/valid_queries.csv"
    [ -f "$VALID" ] || { echo "no valid_queries.csv for $DATASET upstream; use SQLSTORM_QUERY_SET=all" >&2; exit 1; }
    mkdir -p "$(dirname "$DEST")"
    python3 - "$SRC" "$TMP/repo/$SQLSTORM_BASE" "$QUERY_SET" "$LIST" "$DEST.selection.csv" <<'PY'
import collections, csv, json, os, sys
src, base, qset, list_path, sel_path = sys.argv[1:]
status = {}
for name, tag in (("invalid_queries.csv", "excluded_invalid"), ("valid_queries.csv", None)):
    path = os.path.join(base, name)
    if not os.path.exists(path):
        continue
    for r in csv.DictReader(open(path)):
        groups = json.loads(r["systems"])
        if tag is None:
            tag_r = "included" if qset == "valid" or "postgres" in groups[0] else "excluded_postgres_disagrees"
        else:
            tag_r = tag
        status[r["query"]] = (tag_r, r["systems"])
files = sorted(f for f in os.listdir(src) if f.endswith(".sql"))
with open(sel_path, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["query", "status", "systems"])
    for q in files:
        st, systems = status.get(q, ("excluded_unclassified", ""))
        w.writerow([q, st, systems])
tags = {q: status.get(q, ("excluded_unclassified",))[0] for q in files}
open(list_path, "w").write("".join(q + "\n" for q in files if tags[q] == "included"))
counts = collections.Counter(tags.values())
print("    selection (%s): %s" % (qset, ", ".join("%s %d" % kv for kv in sorted(counts.items()))))
PY
fi

echo "==> copying $(wc -l < "$LIST") .sql files into $DEST (prepending the EXPLAIN wrapper)"
rm -rf "$DEST"
mkdir -p "$DEST"
# One awk pass over every file: emit the provenance comment + EXPLAIN line at the
# top of each, pass the body through untouched, and append ';' if the last
# meaningful line (non-blank, not a comment, trailing "-- ..." stripped) does not
# already end in one. Files are processed in a single process, so 17k files take
# seconds rather than minutes.
sed "s#^#$SRC/#" "$LIST" | tr '\n' '\0' | xargs -0 awk \
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
