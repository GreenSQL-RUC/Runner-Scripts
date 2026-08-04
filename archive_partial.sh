#!/usr/bin/env bash
#
# archive_partial.sh - surgically move a query's (or a whole run's) rows out of
# the live result CSVs into an archive, so a bad or partial measurement can be
# pulled without re-running the whole sweep. Matched rows are APPENDED to
# archive/partial/ (nothing is deleted - it is moved and reversible), then
# removed from the live file.
#
# Driven by environment variables (set by `make partial-archive`):
#   QUERY   substring matched against the query column (col 4), so "scan_orders"
#           matches queries/Core/00_baseline/scan_orders.sql; empty = any query
#   RUNID   EXACT match against the run_id column (col 2), the 16-hex per-sweep
#           id. RUNID=<id> alone pulls every row of that run; empty = any run
#   VER     (optional) pg_version filter (col 3): "16" matches 16.x, "16.14"
#           matches exactly; empty = every version
#   DB      (optional) database suffix: only query_*_<DB>.csv are touched;
#           empty = every database's files
#   DRYRUN  (optional) 1 = report what WOULD move and change nothing
#
# At least one of QUERY / RUNID is required. When both are given they AND
# together (e.g. archive just scan_orders' rows from one specific run).
#
# query_timing / query_samples / query_slope are processed; query_catalog is
# left alone (it is per-relation, not per-query).
#
# SAFETY (this is what makes it safe to run alongside the matrix): any CSV that a
# running query_runner currently holds open - i.e. the sweep's ACTIVE database -
# is SKIPPED, so this never races the sweep's appends. Run it against a database
# the sweep is not currently on, or when the sweep is idle.
set -uo pipefail

QUERY="${QUERY:-}"
RUNID="${RUNID:-}"
VER="${VER:-}"
DB="${DB:-}"
DRYRUN="${DRYRUN:-0}"

if [ -z "$QUERY" ] && [ -z "$RUNID" ]; then
    echo "usage: { QUERY=<name> | RUNID=<id> } [VER=<pgver>] [DB=<db>] [DRYRUN=1] bash archive_partial.sh" >&2
    exit 1
fi

ARCHDIR="archive/partial"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BUSY_PID=""

# True (and sets BUSY_PID) if a running query_runner has $1 (an absolute path)
# open. Needs to read other users' /proc/<pid>/fd, hence this runs as root.
busy() {
    local target="$1" pid fd link
    for pid in $(pgrep -x query_runner 2>/dev/null); do
        for fd in /proc/"$pid"/fd/*; do
            link=$(readlink "$fd" 2>/dev/null) || continue
            link=${link% (deleted)}
            if [ "$link" = "$target" ]; then BUSY_PID="$pid"; return 0; fi
        done
    done
    return 1
}

if [ -n "$DB" ]; then
    FILES="query_timing_${DB}.csv query_samples_${DB}.csv query_slope_${DB}.csv"
else
    FILES="$(ls query_timing_*.csv query_samples_*.csv query_slope_*.csv 2>/dev/null)"
fi

echo "partial-archive: QUERY~='${QUERY:-any}'  RUNID='${RUNID:-any}'  VER='${VER:-any}'  DB='${DB:-all}'$([ "$DRYRUN" = 1 ] && echo '   [DRY RUN]')"
mkdir -p "$ARCHDIR"

total=0
touched=0
for f in $FILES; do
    [ -s "$f" ] || continue
    abs="$(readlink -f "$f")"

    if busy "$abs"; then
        echo "  SKIP  $f   (open by a running sweep, PID $BUSY_PID)"
        continue
    fi

    head -1 "$f" > "$TMP/hdr"
    : > "$TMP/match"; : > "$TMP/keep"
    awk -F, -v q="$QUERY" -v rid="$RUNID" -v ver="$VER" -v mf="$TMP/match" -v kf="$TMP/keep" '
        NR == 1 { next }                       # header handled separately
        {
            isq = (q   == "" || index($4, q) > 0)   # col 4 = query (substring)
            isr = (rid == "" || $2 == rid)          # col 2 = run_id (exact)
            isv = (ver == "" || $3 == ver || substr($3, 1, length(ver) + 1) == ver ".")
            if (isq && isr && isv) print > mf; else print > kf
        }' "$f"

    nmatch=$(wc -l < "$TMP/match"); nmatch=${nmatch:-0}
    if [ "$nmatch" -eq 0 ]; then
        echo "  --    $f   (no matching rows)"
        continue
    fi
    nkeep=$(wc -l < "$TMP/keep")

    if [ "$DRYRUN" = 1 ]; then
        echo "  WOULD $f   archive $nmatch row(s), keep $nkeep  (run_id,pg_version,query):"
        cut -d, -f2,3,4 "$TMP/match" | sort | uniq -c | sed 's/^/          /'
        total=$((total + nmatch)); touched=$((touched + 1))
        continue
    fi

    # Re-check right before mutating to shrink the race window with the sweep.
    if busy "$abs"; then
        echo "  SKIP  $f   (became busy before write)"
        continue
    fi

    arch="$ARCHDIR/$(basename "$f")"
    [ -s "$arch" ] || cat "$TMP/hdr" > "$arch"      # header once
    cat "$TMP/match" >> "$arch"
    cat "$TMP/hdr" "$TMP/keep" > "$TMP/newsrc"
    mv "$TMP/newsrc" "$f"                            # atomic replace
    chmod 644 "$f" 2>/dev/null || true
    echo "  MOVE  $f   ->  $arch   (archived $nmatch, kept $nkeep)"
    total=$((total + nmatch)); touched=$((touched + 1))
done

# Hand the archives back to the invoking user when run under sudo.
if [ "$DRYRUN" != 1 ] && [ -n "${SUDO_UID:-}" ] && [ -d "$ARCHDIR" ]; then
    chown -R "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$ARCHDIR" 2>/dev/null || true
fi

if [ "$touched" -eq 0 ]; then
    echo "partial-archive: nothing matched (0 rows)"
else
    echo "partial-archive: $([ "$DRYRUN" = 1 ] && echo 'would move' || echo 'moved') $total row(s) across $touched file(s)"
fi
