#!/usr/bin/env python3
"""
Generate the WRITE (data-mutating) benchmark corpus under queries/write/tpch/.

Companion to the read generators (queries/generate_*.py), but every statement
here MUTATES data, so the design is different:

  * ISOLATION. These run only against the disposable scratch database
    (tpch_write) via write_runner, which refuses the canonical read databases.
    Each file reads the scratch DB's own read-only reference tables (lineitem,
    ...) to (re)build small "w_*" scratch tables - the only things ever written.

  * PER-RUN RESET. Writes are not idempotent, so each file is split by a
    "-- @MEASURE" line into a SETUP section (rebuilds a pristine w_* table; run
    and committed before EVERY measured run, NOT timed) and the MEASURED write
    (the single statement whose energy/time we record).

  * SCALING. Operations whose cost scales with row count come in small / medium
    / large variants (1e3 / 1e5 / 1e6 rows) so linearity can be judged from at
    least three points. This mirrors the read corpus's fixed-size-variant style
    (e.g. 04_join_scale) and keeps the runner and the data deterministic - no
    runtime scale knob. LIMIT n over the static, unordered reference table is
    stable, and "small" rows are a prefix of "large", so runs are repeatable.

Run:  python3 build/generate_tpch_write_queries.py
"""
import os
import shutil

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))       # repo root (this file is in build/)
OUT  = os.path.join(REPO, "queries", "write", "tpch")                    # queries/write/tpch/

SIZES = [("small", 1_000), ("medium", 100_000), ("large", 1_000_000)]


# ---- SETUP snippets (rebuild a pristine scratch table; not timed) ----------
def empty_like():
    return ("DROP TABLE IF EXISTS w_lineitem;\n"
            "CREATE TABLE w_lineitem (LIKE lineitem INCLUDING DEFAULTS);")


def populated(n, indexed=False):
    s = ("DROP TABLE IF EXISTS w_lineitem;\n"
         "CREATE TABLE w_lineitem AS SELECT * FROM lineitem LIMIT %d;" % n)
    if indexed:
        s += "\nCREATE INDEX w_lineitem_key ON w_lineitem(l_orderkey);"
    return s


# ---- The corpus: (section_dir, title, [ (name, note, setup, measure), ... ]) -
SPEC = []

# ----------------------------------------------------------------- 01 insert
_insert = []
for size, n in SIZES:
    _insert.append(("bulk_%s" % size,
        "Bulk INSERT ... SELECT of %d rows into an empty heap (no indexes)." % n,
        empty_like(),
        "INSERT INTO w_lineitem SELECT * FROM lineitem LIMIT %d;" % n))
_insert += [
    ("single_row",
     "One-row INSERT: the per-statement floor (parse/plan/commit dominate).",
     empty_like(),
     "INSERT INTO w_lineitem SELECT * FROM lineitem LIMIT 1;"),
    ("indexed_target_medium",
     "Bulk INSERT (100k) into a table that HAS an index: adds index maintenance\n"
     "on top of the heap insert - compare bulk_medium (no index).",
     "DROP TABLE IF EXISTS w_lineitem;\n"
     "CREATE TABLE w_lineitem (LIKE lineitem INCLUDING DEFAULTS);\n"
     "CREATE INDEX w_lineitem_key ON w_lineitem(l_orderkey);",
     "INSERT INTO w_lineitem SELECT * FROM lineitem LIMIT 100000;"),
    ("on_conflict_medium",
     "Upsert: INSERT ... ON CONFLICT DO UPDATE of 100k rows into a 50k table so\n"
     "half collide (UPDATE path) and half are new (INSERT path).",
     "DROP TABLE IF EXISTS w_upsert;\n"
     "CREATE TABLE w_upsert AS SELECT * FROM lineitem LIMIT 50000;\n"
     "ALTER TABLE w_upsert ADD PRIMARY KEY (l_orderkey, l_linenumber);",
     "INSERT INTO w_upsert SELECT * FROM lineitem LIMIT 100000\n"
     "ON CONFLICT (l_orderkey, l_linenumber) DO UPDATE SET l_quantity = EXCLUDED.l_quantity;"),
]
SPEC.append(("01_insert", "INSERT: bulk load, single row, indexed target, upsert", _insert))

# ----------------------------------------------------------------- 02 update
_update = []
for size, n in SIZES:
    _update.append(("all_%s" % size,
        "UPDATE every one of %d rows (each becomes a new tuple version)." % n,
        populated(n),
        "UPDATE w_lineitem SET l_quantity = l_quantity + 1;"))
_update += [
    ("indexed_col_medium",
     "UPDATE an INDEXED column (100k rows): each row's index entry must move,\n"
     "so this pays heap + index churn.",
     populated(100000, indexed=True),
     "UPDATE w_lineitem SET l_orderkey = l_orderkey + 1;"),
    ("hot_medium",
     "UPDATE a NON-indexed column on the same indexed table: a Heap-Only Tuple\n"
     "update with no index churn - the pair with indexed_col_medium.",
     populated(100000, indexed=True),
     "UPDATE w_lineitem SET l_quantity = l_quantity + 1;"),
    ("single_row",
     "UPDATE one row located by an indexed key.",
     populated(100000, indexed=True),
     "UPDATE w_lineitem SET l_quantity = l_quantity + 1 WHERE l_orderkey = 1;"),
]
SPEC.append(("02_update", "UPDATE: bulk, indexed-column churn vs HOT, single row", _update))

# ----------------------------------------------------------------- 03 delete
_delete = []
for size, n in SIZES:
    _delete.append(("bulk_%s" % size,
        "DELETE ~half of a %d-row table (l_quantity <= 25)." % n,
        populated(n),
        "DELETE FROM w_lineitem WHERE l_quantity <= 25;"))
_delete += [
    ("all_medium",
     "DELETE every row (100k): full-table delete, marks all tuples dead\n"
     "(compare truncate_medium).",
     populated(100000),
     "DELETE FROM w_lineitem;"),
    ("truncate_medium",
     "TRUNCATE the same 100k table: a metadata/file operation, not a per-row\n"
     "delete - the cheap contrast with all_medium.",
     populated(100000),
     "TRUNCATE w_lineitem;"),
    ("single_row",
     "DELETE one row located by an indexed key.",
     populated(100000, indexed=True),
     "DELETE FROM w_lineitem WHERE l_orderkey = 1;"),
]
SPEC.append(("03_delete", "DELETE: bulk, delete-all vs TRUNCATE, single row", _delete))

# ----------------------------------------------------------------- 04 copy
_copy = []
for size, n in SIZES:
    f = "/tmp/w_copy_%s.csv" % size
    _copy.append(("copy_%s" % size,
        "Bulk load of %d rows via server-side COPY FROM (the fast load path).\n"
        "SETUP writes the data file with COPY ... TO; only COPY FROM is timed." % n,
        "DROP TABLE IF EXISTS w_lineitem;\n"
        "CREATE TABLE w_lineitem (LIKE lineitem INCLUDING DEFAULTS);\n"
        "COPY (SELECT * FROM lineitem LIMIT %d) TO '%s' WITH (FORMAT csv);" % (n, f),
        "COPY w_lineitem FROM '%s' WITH (FORMAT csv);" % f))
SPEC.append(("04_copy", "COPY: bulk load at three scales", _copy))

# ----------------------------------------------------------------- 05 index/ddl
_ddl = []
for size, n in SIZES:
    _ddl.append(("create_index_%s" % size,
        "Build a btree index over %d rows (CREATE INDEX sort + write)." % n,
        populated(n),
        "CREATE INDEX w_lineitem_bx ON w_lineitem(l_partkey);"))
_ddl += [
    ("reindex_medium",
     "REINDEX an existing btree (100k): rebuild it from scratch.",
     populated(100000, indexed=True),
     "REINDEX INDEX w_lineitem_key;"),
    ("cluster_medium",
     "CLUSTER a 100k table on its index: a full table rewrite in index order.",
     populated(100000, indexed=True),
     "CLUSTER w_lineitem USING w_lineitem_key;"),
]
SPEC.append(("05_index_ddl", "DDL: index build, REINDEX, CLUSTER", _ddl))

# ----------------------------------------------------------------- 06 maintenance
_maint = [
    ("vacuum_medium",
     "VACUUM a table with 100k dead tuples (SETUP updates every row first):\n"
     "reclaims them for reuse without rewriting the file.",
     populated(100000) + "\nUPDATE w_lineitem SET l_quantity = l_quantity + 1;",
     "VACUUM w_lineitem;"),
    ("vacuum_full_medium",
     "VACUUM FULL on the same bloated table: rewrites the whole heap to shrink it.",
     populated(100000) + "\nUPDATE w_lineitem SET l_quantity = l_quantity + 1;",
     "VACUUM FULL w_lineitem;"),
    ("analyze_medium",
     "ANALYZE: resample planner statistics over 100k rows.",
     populated(100000),
     "ANALYZE w_lineitem;"),
]
SPEC.append(("06_maintenance", "Maintenance: VACUUM, VACUUM FULL, ANALYZE", _maint))

# ----------------------------------------------------------------- 07 durability
_dur = [
    ("sync_commit_on_medium",
     "100k INSERT with synchronous_commit=on: the commit waits for the WAL fsync.",
     empty_like(),
     "SET synchronous_commit = on;\n"
     "INSERT INTO w_lineitem SELECT * FROM lineitem LIMIT 100000;"),
    ("sync_commit_off_medium",
     "Same 100k INSERT with synchronous_commit=off: no per-commit fsync wait -\n"
     "the durability-cost pair with sync_commit_on_medium.",
     empty_like(),
     "SET synchronous_commit = off;\n"
     "INSERT INTO w_lineitem SELECT * FROM lineitem LIMIT 100000;"),
    ("unlogged_medium",
     "100k INSERT into an UNLOGGED table: skips WAL entirely - compare\n"
     "01_insert/bulk_medium (logged).",
     "DROP TABLE IF EXISTS w_unlogged;\n"
     "CREATE UNLOGGED TABLE w_unlogged (LIKE lineitem INCLUDING DEFAULTS);",
     "INSERT INTO w_unlogged SELECT * FROM lineitem LIMIT 100000;"),
]
SPEC.append(("07_durability", "Durability: synchronous_commit on/off, UNLOGGED", _dur))

# ----------------------------------------------------------------- 08 transaction
_txn = [
    ("rollback_medium",
     "100k INSERT then ROLLBACK: measures write WORK (WAL generation, tuple\n"
     "building) WITHOUT the durable commit - the 'work mode' counterpart to a\n"
     "committed bulk INSERT. The ROLLBACK also self-resets the table.",
     empty_like(),
     "BEGIN;\n"
     "INSERT INTO w_lineitem SELECT * FROM lineitem LIMIT 100000;\n"
     "ROLLBACK;"),
    ("many_statements",
     "10,000 one-row INSERTs in a single transaction (a procedural loop):\n"
     "isolates per-statement executor overhead against one bulk INSERT.",
     empty_like(),
     "DO $$ BEGIN\n"
     "  FOR i IN 1..10000 LOOP\n"
     "    INSERT INTO w_lineitem SELECT * FROM lineitem LIMIT 1;\n"
     "  END LOOP;\n"
     "END $$;"),
]
SPEC.append(("08_transaction", "Transactions: rollback (work-only), many small statements", _txn))

# ----------------------------------------------------------------- 09 merge
_merge = [
    ("merge_medium",
     "MERGE (PG15+): 100k source rows into a 50k target keyed on\n"
     "(l_orderkey, l_linenumber) - half UPDATE (matched), half INSERT (not).",
     "DROP TABLE IF EXISTS w_target;\n"
     "CREATE TABLE w_target AS SELECT l_orderkey, l_linenumber, l_quantity FROM lineitem LIMIT 50000;\n"
     "ALTER TABLE w_target ADD PRIMARY KEY (l_orderkey, l_linenumber);\n"
     "DROP TABLE IF EXISTS w_source;\n"
     "CREATE TABLE w_source AS SELECT l_orderkey, l_linenumber, l_quantity FROM lineitem LIMIT 100000;",
     "MERGE INTO w_target t USING w_source s\n"
     "  ON t.l_orderkey = s.l_orderkey AND t.l_linenumber = s.l_linenumber\n"
     "  WHEN MATCHED THEN UPDATE SET l_quantity = s.l_quantity\n"
     "  WHEN NOT MATCHED THEN INSERT (l_orderkey, l_linenumber, l_quantity)\n"
     "    VALUES (s.l_orderkey, s.l_linenumber, s.l_quantity);"),
]
SPEC.append(("09_merge", "MERGE: matched-update / not-matched-insert", _merge))


# ------------------------------------------------------------------- render
def render(section_title, name, note, setup, measure):
    lines = ["-- %s" % section_title, "-- Operation: %s" % name]
    for ln in note.split("\n"):
        lines.append("-- " + ln)
    lines.append("-- Isolated write: runs only on the scratch DB (tpch_write). Everything above")
    lines.append("-- the marker line is SETUP - it rebuilds a disposable w_* table from read-only")
    lines.append("-- reference data and is NOT timed. write_runner then quiesces the scratch tables,")
    lines.append("-- drops caches and restarts the cluster, so only the statement below the marker")
    lines.append("-- is measured, always from a cold start.")
    lines.append(setup.rstrip())
    lines.append("-- @MEASURE")
    lines.append(measure.rstrip())
    return "\n".join(lines) + "\n"


def main():
    total = 0
    for section_dir, title, ops in SPEC:
        d = os.path.join(OUT, section_dir)
        if os.path.isdir(d):
            shutil.rmtree(d)
        os.makedirs(d)
        for name, note, setup, measure in ops:
            with open(os.path.join(d, name + ".sql"), "w") as fh:
                fh.write(render(title, name, note, setup, measure))
            total += 1
        print("%-24s %2d queries" % (section_dir, len(ops)))
    print("-" * 36)
    print("%-24s %2d queries" % ("TOTAL", total))


if __name__ == "__main__":
    main()
