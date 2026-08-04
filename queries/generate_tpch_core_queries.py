#!/usr/bin/env python3
"""
Generate one benchmark query per core relational operation (scans, joins,
grouping, sorting, set operations, subqueries).

Companion to generate_tpch_function_queries.py: that script covers PostgreSQL's
Chapter 9 functions/operators (per-row expression cost); this one covers the
PLAN-LEVEL operations that were missing - the executor nodes a real query is
actually built from. Same design decisions apply:

  * ONE OPERATION PER FILE - each file isolates a single plan node or plan
                   shape, so its energy number is attributable to that node.
  * EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS) executes the plan
                   but discards rows server-side; nothing crosses the wire.
                   SUMMARY ON prints Planning/Execution Time and BUFFERS prints
                   block counts, both of which the runner parses into the
                   per-run samples CSV. Neither changes what is executed and
                   neither is measurable in the runtime (both counters are
                   maintained regardless); they only add two output lines.
  * NO LIMIT unless the LIMIT itself is the operation under test.
  * BASELINES  - 00_baseline holds one seq scan per TPC-H table plus a
                   no-table query. Isolate an operator by subtracting the
                   scan cost of its input table(s) and the fixed per-run
                   overhead (psql startup + parse/plan) from its number.
  * OPTIMIZER-CHOSEN PARALLELISM - no file caps workers; the planner decides
                   whether, and how many, Gather workers to add, exactly as
                   in production, matching queries/Functions and keeping
                   optimizer overrides to a minimum. To sweep the whole suite
                   at a fixed cap instead, pass WORKERS to the runner
                   (make run WORKERS=2): it applies
                   max_parallel_workers_per_gather=N to every query via
                   PGOPTIONS, WORKERS=0 giving a fully serial baseline.
                   Trade-off: at the default the planner may parallelize some
                   files and not others (e.g. a selective filter vs a 100%
                   one), so read per-operation energy alongside the plan
                   (see ./plans) rather than assuming equal worker counts.
  * PINNED SCANS - files whose target list touches only an indexed column
                   would silently flip to an index-only scan and stop being
                   comparable with the seq-scan baselines, so those files
                   disable enable_indexonlyscan. 01_scan_access measures the
                   index-only scan deliberately.

Some files force a specific plan with "SET enable_<node> = off;" lines before
the EXPLAIN. The runner executes each file in its own psql process, so these
session settings die with the process: nothing persists, and no data is ever
written (pure SELECT under EXPLAIN throughout).

Table sizes on the SF-1 database this was written against:
    lineitem 6,001,215   orders 1,500,000   partsupp 800,000
    part       200,000   customer  150,000  supplier  10,000
    nation          25   region          5
Indexes (from old/tpch_prep.sql): lineitem(l_orderkey) [table CLUSTERed on
it], orders(o_custkey), customer(c_nationkey). Everything else is seq-scan
territory.

Usage:  python3 queries/generate_tpch_core_queries.py
Re-run it after editing SPEC to regenerate queries/tpch/Core/.
"""

import os
import shutil

OUT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tpch", "Core")

HEADER = "EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)"


def op(name, sql, off=(), sets=(), note=None):
    """One benchmark query.

    name : file name (without .sql)
    sql  : full statement (the EXPLAIN header is prepended automatically)
    off  : planner GUCs to disable first, e.g. ("mergejoin", "nestloop")
           -> "SET enable_mergejoin = off;" lines before the EXPLAIN
    sets : raw session settings, e.g. ("work_mem = '4MB'", "jit = on") ->
           "SET work_mem = '4MB';" lines (12_memory_workmem and 13_jit use it
           for work_mem / jit). Worker count is never set here - it is a
           global runner knob (WORKERS); files leave it to the planner.
    note : extra comment lines for this file
    """
    return (name, sql, tuple(off), tuple(sets), note)


# Each section: (directory, human title, section note, [op(...), ...])
SPEC = []

# ----------------------------------------------------------------- baselines
SPEC.append(("00_baseline", "Baselines: one seq scan per table",
 "Subtract the scan cost of an operator's input table(s) from its measurement\n"
 "-- to isolate the operator itself (a join reads two tables: subtract both).\n"
 "-- no_table measures the fixed per-run overhead every file pays: psql\n"
 "-- startup, parse/plan, EXPLAIN machinery. Narrowest int column projected\n"
 "-- so the target list adds as little as possible.", [
    op("no_table",      "SELECT 1"),
    op("scan_region",   "SELECT r_regionkey FROM region"),
    op("scan_nation",   "SELECT n_nationkey FROM nation"),
    op("scan_supplier", "SELECT s_suppkey FROM supplier"),
    op("scan_customer", "SELECT c_custkey FROM customer"),
    op("scan_part",     "SELECT p_partkey FROM part"),
    op("scan_partsupp", "SELECT ps_partkey FROM partsupp"),
    op("scan_orders",   "SELECT o_orderkey FROM orders"),
    op("scan_lineitem", "SELECT l_orderkey FROM lineitem",
       off=("indexonlyscan",),
       note="l_orderkey is indexed, so the index-only scan is pinned off to\n"
            "-- keep this the SEQ SCAN baseline the other sections subtract."),
]))

# ----------------------------------------------------------------- access methods
SPEC.append(("01_scan_access", "Access methods: same rows, different scan node",
 "All range queries fetch the same ~600k rows (~10% of lineitem) via\n"
 "-- l_orderkey BETWEEN 1 AND 600000, so the files differ only in the scan\n"
 "-- node used. The table is CLUSTERed on l_orderkey, so the index reads\n"
 "-- contiguous heap pages - this is the friendly case for index scans.", [
    op("seq_scan",
       "SELECT l_partkey FROM lineitem WHERE l_orderkey BETWEEN 1 AND 600000",
       off=("indexscan", "indexonlyscan", "bitmapscan")),
    op("index_scan",
       "SELECT l_partkey FROM lineitem WHERE l_orderkey BETWEEN 1 AND 600000",
       off=("seqscan", "bitmapscan"),
       note="Projecting l_partkey (not in the index) forces heap fetches."),
    op("bitmap_scan",
       "SELECT l_partkey FROM lineitem WHERE l_orderkey BETWEEN 1 AND 600000",
       off=("seqscan", "indexscan", "indexonlyscan")),
    op("index_only_scan",
       "SELECT l_orderkey FROM lineitem WHERE l_orderkey BETWEEN 1 AND 600000",
       off=("seqscan", "bitmapscan"),
       note="Only the indexed column is projected, so the heap is skipped for\n"
            "-- pages marked all-visible; run VACUUM first or 'Heap Fetches'\n"
            "-- in the plan will be high and this degrades toward index_scan."),
    op("index_point_lookup",
       "SELECT l_partkey FROM lineitem WHERE l_orderkey = 3000000",
       off=("seqscan", "bitmapscan"),
       note="A single-key probe (a few rows): the OLTP access pattern. Almost\n"
            "-- all of its measurement is the fixed no_table overhead."),
    op("tablesample_system",
       "SELECT l_partkey FROM lineitem TABLESAMPLE SYSTEM (1)",
       note="Sample Scan, block-level: reads ~1% of the HEAP PAGES (cheap),\n"
            "-- returning whatever rows those pages hold. Read-only sampling."),
    op("tablesample_bernoulli",
       "SELECT l_partkey FROM lineitem TABLESAMPLE BERNOULLI (1)",
       note="Sample Scan, row-level: visits EVERY row and keeps each with 1%\n"
            "-- probability, so it costs a full scan - the SYSTEM/BERNOULLI pair\n"
            "-- prices block- vs row-level sampling."),
]))

# ----------------------------------------------------------------- filter / projection
SPEC.append(("02_filter_projection", "Filter selectivity and projection width",
 "l_quantity is uniform on 1..50, so the filter series passes ~0%, ~2%, ~50%\n"
 "-- and 100% of the 6M rows while evaluating the same predicate on every row:\n"
 "-- the difference between the files is the cost of EMITTING rows, the\n"
 "-- difference from scan_lineitem is the predicate itself. The projection\n"
 "-- pair varies only the width of the target list.", [
    op("filter_none",  "SELECT l_orderkey FROM lineitem WHERE l_quantity < 0"),
    op("filter_2pct",  "SELECT l_orderkey FROM lineitem WHERE l_quantity < 2"),
    op("filter_half",  "SELECT l_orderkey FROM lineitem WHERE l_quantity <= 25"),
    op("filter_all",   "SELECT l_orderkey FROM lineitem WHERE l_quantity > 0"),
    op("project_zero_cols", "SELECT FROM lineitem",
       off=("indexonlyscan",),
       note="Empty target list (valid in PostgreSQL): pure tuple-iteration\n"
            "-- cost with no column extraction at all."),
    op("project_all_cols", "SELECT * FROM lineitem",
       note="All 16 columns: compare with scan_lineitem (1 column) for the\n"
            "-- cost of target-list width."),
    op("limit_100", "SELECT l_orderkey FROM lineitem LIMIT 100",
       off=("indexonlyscan",),
       note="Early termination: the scan stops after ~100 rows, so this\n"
            "-- measures close to the no_table overhead."),
    op("limit_offset_3m",
       "SELECT l_orderkey FROM lineitem LIMIT 100 OFFSET 3000000",
       off=("indexonlyscan",),
       note="OFFSET rows are fully fetched and discarded: half the scan cost\n"
            "-- despite returning 100 rows."),
]))

# ----------------------------------------------------------------- join methods
SPEC.append(("03_join_method", "Join methods: same join, forced algorithm",
 "Each trio computes the IDENTICAL join with a different algorithm, forced by\n"
 "-- disabling the other methods. large_* = orders JOIN customer (1.5M x 150k,\n"
 "-- output 1.5M rows); small_* = supplier JOIN nation (10k x 25, output 10k).\n"
 "-- Subtract the two input-table scans from 00_baseline to isolate the join.\n"
 "-- No unindexed nestloop on the large pair: 1.5M x 150k row comparisons is\n"
 "-- pathological (hours). The indexed variant probes orders(o_custkey) instead.", [
    op("large_hash",
       "SELECT 1 FROM orders o JOIN customer c ON o.o_custkey = c.c_custkey",
       off=("mergejoin", "nestloop", "indexonlyscan")),
    op("large_merge",
       "SELECT 1 FROM orders o JOIN customer c ON o.o_custkey = c.c_custkey",
       off=("hashjoin", "nestloop", "indexscan", "indexonlyscan"),
       note="Index scans pinned off too, so this is the canonical sort + sort\n"
            "-- + merge (otherwise the planner reads orders pre-ordered via\n"
            "-- idx_orders_cust and skips one sort)."),
    op("large_nestloop_index",
       "SELECT 1 FROM orders o JOIN customer c ON o.o_custkey = c.c_custkey",
       off=("hashjoin", "mergejoin", "indexonlyscan"),
       note="~150k outer rows each probing idx_orders_cust: the OLTP join."),
    op("small_hash",
       "SELECT 1 FROM supplier s JOIN nation n ON s.s_nationkey = n.n_nationkey",
       off=("mergejoin", "nestloop", "indexonlyscan")),
    op("small_merge",
       "SELECT 1 FROM supplier s JOIN nation n ON s.s_nationkey = n.n_nationkey",
       off=("hashjoin", "nestloop", "indexonlyscan")),
    op("small_nestloop",
       "SELECT 1 FROM supplier s JOIN nation n ON s.s_nationkey = n.n_nationkey",
       off=("hashjoin", "mergejoin", "indexonlyscan"),
       note="Unindexed nestloop is safe here: 10k x 25 comparisons."),
]))

# ----------------------------------------------------------------- join scaling
SPEC.append(("04_join_scale", "Join cost vs input size (hash join forced)",
 "The same many-to-one key join at every size the schema offers, all forced\n"
 "-- to hash join so the numbers form one comparable series. File names give\n"
 "-- outer x inner input sizes; output rows = outer rows for each. Subtract\n"
 "-- the two input scans (00_baseline) to get the join-node cost alone.", [
    op("join_25x5",
       "SELECT 1 FROM nation n JOIN region r ON n.n_regionkey = r.r_regionkey",
       off=("mergejoin", "nestloop", "indexonlyscan")),
    op("join_10kx25",
       "SELECT 1 FROM supplier s JOIN nation n ON s.s_nationkey = n.n_nationkey",
       off=("mergejoin", "nestloop", "indexonlyscan")),
    op("join_150kx25",
       "SELECT 1 FROM customer c JOIN nation n ON c.c_nationkey = n.n_nationkey",
       off=("mergejoin", "nestloop", "indexonlyscan")),
    op("join_800kx200k",
       "SELECT 1 FROM partsupp ps JOIN part p ON ps.ps_partkey = p.p_partkey",
       off=("mergejoin", "nestloop", "indexonlyscan")),
    op("join_1500kx150k",
       "SELECT 1 FROM orders o JOIN customer c ON o.o_custkey = c.c_custkey",
       off=("mergejoin", "nestloop", "indexonlyscan")),
    op("join_6mx10k",
       "SELECT 1 FROM lineitem l JOIN supplier s ON l.l_suppkey = s.s_suppkey",
       off=("mergejoin", "nestloop", "indexonlyscan")),
    op("join_6mx200k",
       "SELECT 1 FROM lineitem l JOIN part p ON l.l_partkey = p.p_partkey",
       off=("mergejoin", "nestloop", "indexonlyscan")),
    op("join_6mx1500k",
       "SELECT 1 FROM lineitem l JOIN orders o ON l.l_orderkey = o.o_orderkey",
       off=("mergejoin", "nestloop", "indexonlyscan")),
]))

# ----------------------------------------------------------------- join types
SPEC.append(("05_join_type", "Join semantics on one pair (planner free to choose)",
 "orders JOIN customer throughout (except cross/self), varying only the join\n"
 "-- TYPE. Every file is pinned to a hash join over seq scans (same pins as\n"
 "-- 04_join_scale), so the differences are purely what the semantics add:\n"
 "-- outer-row emission, dedup for semi, full-side tracking, etc.", [
    op("inner",
       "SELECT 1 FROM orders o JOIN customer c ON o.o_custkey = c.c_custkey",
       off=("mergejoin", "nestloop", "indexonlyscan")),
    op("left_outer",
       "SELECT 1 FROM orders o LEFT JOIN customer c ON o.o_custkey = c.c_custkey",
       off=("mergejoin", "nestloop", "indexonlyscan")),
    op("right_outer",
       "SELECT 1 FROM orders o RIGHT JOIN customer c ON o.o_custkey = c.c_custkey",
       off=("mergejoin", "nestloop", "indexonlyscan")),
    op("full_outer",
       "SELECT 1 FROM orders o FULL JOIN customer c ON o.o_custkey = c.c_custkey",
       off=("mergejoin", "nestloop", "indexonlyscan")),
    op("semi_exists",
       "SELECT 1 FROM orders o WHERE EXISTS "
       "(SELECT 1 FROM customer c WHERE c.c_custkey = o.o_custkey)",
       off=("mergejoin", "nestloop", "indexonlyscan"),
       note="Hash Semi Join with the same scans and build side as inner; each\n"
            "-- probe stops at the first match. (EXISTS written the other way\n"
            "-- around gets planned as HashAggregate dedup + plain join instead\n"
            "-- of a semi-join node.)"),
    op("anti_not_exists",
       "SELECT 1 FROM orders o WHERE NOT EXISTS "
       "(SELECT 1 FROM customer c WHERE c.c_custkey = o.o_custkey)",
       off=("mergejoin", "nestloop", "indexonlyscan"),
       note="Hash Anti Join, same probe work as semi_exists but emitting the\n"
            "-- NON-matches (none here: every order has a customer, output 0)."),
    op("self_join",
       "SELECT 1 FROM orders o1 JOIN orders o2 ON o1.o_orderkey = o2.o_orderkey",
       off=("mergejoin", "nestloop", "indexonlyscan"),
       note="Same table on both sides (1.5M x 1.5M on the key, output 1.5M):\n"
            "-- compare with join_1500kx150k for the effect of build-side size."),
    op("cross_join",
       "SELECT 1 FROM region CROSS JOIN orders",
       off=("indexonlyscan",),
       note="EXPANDS rows: 5 x 1.5M = 7.5M output. Kept small on purpose -\n"
            "-- a cross join of two large tables would be pathological. A cross\n"
            "-- join is always a nested loop, so only the scans are pinned."),
    op("join_on_text_cast",
       "SELECT 1 FROM orders o JOIN customer c "
       "ON o.o_custkey::text = c.c_custkey::text",
       off=("mergejoin", "nestloop", "indexonlyscan"),
       note="Same hash join as inner but hashing/comparing TEXT keys instead\n"
            "-- of int; the measurement includes the per-row int->text casts.\n"
            "-- (Left unpinned the planner picks a merge join here.)"),
]))

# ----------------------------------------------------------------- join chains
# Each step adds one many-to-one join that PRESERVES the 6M-row output, so a
# chain of depth N is N joins deep. The same chain is built three times, once
# per join method, giving parallel scaling series that can be compared.
_CHAIN_STEPS = [
    ("orders",   "JOIN orders o ON l.l_orderkey = o.o_orderkey"),
    ("customer", "JOIN customer c ON o.o_custkey = c.c_custkey"),
    ("nation",   "JOIN nation n ON c.c_nationkey = n.n_nationkey"),
    ("region",   "JOIN region r ON n.n_regionkey = r.r_regionkey"),
]
# Force ONE join method per variant (disable the other two) and leave scans,
# sorts and parallelism to the planner, so each method runs in its natural form.
_CHAIN_METHODS = [
    ("hash",     ("mergejoin", "nestloop")),
    ("merge",    ("hashjoin", "nestloop")),
    ("nestloop", ("hashjoin", "mergejoin")),
]
_chain_ops = []
for _depth in range(1, len(_CHAIN_STEPS) + 1):
    _body = "FROM lineitem l " + " ".join(sql for _, sql in _CHAIN_STEPS[:_depth])
    _path = "lineitem -> " + " -> ".join(t for t, _ in _CHAIN_STEPS[:_depth])
    for _method, _offs in _CHAIN_METHODS:
        _chain_ops.append(op(
            "chain_%d_%s" % (_depth, _method),
            "SELECT 1 " + _body,
            off=_offs,
            note="%s join, %d-join chain (%s)." % (_method.capitalize(), _depth, _path)))
SPEC.append(("06_join_chain", "Join-count scaling per join method: 1 to 4 joins",
 "Three parallel series - hash / merge / nestloop - each add one many-to-one\n"
 "-- join at a time, all preserving the 6M-row output. Within a series the\n"
 "-- consecutive difference (chain_N vs chain_N-1) is the incremental cost of\n"
 "-- join N, and the chain_1 -> chain_4 slope is that method's scaling curve.\n"
 "-- Only the join METHOD is forced (the other two are disabled); scans, sorts\n"
 "-- and parallelism are the planner's choice, so each method runs in its\n"
 "-- natural form. The scan nodes therefore differ BETWEEN methods (nestloop\n"
 "-- probes indexes; hash builds hash tables; merge sorts inputs), so compare\n"
 "-- the scaling SHAPE across methods, not raw cross-method deltas. nestloop\n"
 "-- stays feasible only because the added tables are reachable by index\n"
 "-- (idx_lineitem_order / idx_orders_cust / idx_customer_nation) when the\n"
 "-- planner drives from the small end (region -> ... -> lineitem); without\n"
 "-- those indexes a forced nestloop chain would be pathological.", _chain_ops))

# ----------------------------------------------------------------- grouping / distinct
SPEC.append(("07_grouping_distinct", "Grouping and duplicate elimination",
 "Bare GROUP BY (no aggregate) isolates the grouping machinery itself; the\n"
 "-- group-count series varies only the number of groups the hash table must\n"
 "-- hold (3 -> 7 -> 200k -> 1.5M) over the same 6M input rows. Aggregate\n"
 "-- FUNCTION costs live in Functions/09-21_aggregate.", [
    op("group_3_vals",     "SELECT l_returnflag FROM lineitem GROUP BY l_returnflag"),
    op("group_7_vals",     "SELECT l_shipmode FROM lineitem GROUP BY l_shipmode"),
    op("group_200k_vals",  "SELECT l_partkey FROM lineitem GROUP BY l_partkey"),
    op("group_1500k_vals", "SELECT l_orderkey FROM lineitem GROUP BY l_orderkey",
       off=("indexscan", "indexonlyscan"),
       note="Index scans pinned off: l_orderkey is indexed and the planner\n"
            "-- would otherwise group pre-ordered index output, leaving the\n"
            "-- series. At 1.5M groups the hash table exceeds work_mem and\n"
            "-- spills - that cliff is part of what this file measures."),
    op("group_200k_sortagg",
       "SELECT l_partkey FROM lineitem GROUP BY l_partkey",
       off=("hashagg",),
       note="Same query as group_200k_vals but forced to sort + GroupAggregate:\n"
            "-- the hash-vs-sort grouping strategy pair."),
    op("count_per_group",
       "SELECT l_returnflag, count(*) FROM lineitem GROUP BY l_returnflag",
       note="Compare with group_3_vals: the delta is the per-row count(*)."),
    op("having",
       "SELECT l_partkey FROM lineitem GROUP BY l_partkey HAVING count(*) > 30",
       note="Compare with group_200k_vals: adds a count per group plus the\n"
            "-- post-group filter."),
    op("distinct_3_vals",   "SELECT DISTINCT l_returnflag FROM lineitem",
       note="Semantically identical to group_3_vals - a planner equivalence pair."),
    op("distinct_200k_vals", "SELECT DISTINCT l_partkey FROM lineitem"),
    op("distinct_on",
       "SELECT DISTINCT ON (l_returnflag) l_returnflag, l_shipdate "
       "FROM lineitem ORDER BY l_returnflag, l_shipdate",
       note="Includes the mandatory 6M-row sort, which dominates."),
    op("rollup",
       "SELECT l_returnflag, l_linestatus FROM lineitem "
       "GROUP BY ROLLUP (l_returnflag, l_linestatus)"),
    op("cube",
       "SELECT l_returnflag, l_linestatus FROM lineitem "
       "GROUP BY CUBE (l_returnflag, l_linestatus)"),
    op("grouping_sets",
       "SELECT l_returnflag, l_linestatus FROM lineitem "
       "GROUP BY GROUPING SETS ((l_returnflag), (l_linestatus))"),
]))

# ----------------------------------------------------------------- sorting
SPEC.append(("08_sorting", "Sorting 6M rows: key type, direction, top-N",
 "Only the sort key is projected, so the files differ in comparator cost and\n"
 "-- sorted-row width alone. At default work_mem these sorts spill to an\n"
 "-- external merge on disk - that is the realistic case and is part of the\n"
 "-- measurement.", [
    op("sort_int",      "SELECT l_partkey FROM lineitem ORDER BY l_partkey"),
    op("sort_int_presorted",
       "SELECT l_orderkey FROM lineitem ORDER BY l_orderkey",
       off=("indexscan", "indexonlyscan"),
       note="The table is CLUSTERed on l_orderkey, so input arrives nearly\n"
            "-- sorted: same Sort node as sort_int on friendlier data. Index\n"
            "-- scans are pinned off - otherwise the planner reads the index\n"
            "-- in order and drops the Sort node entirely."),
    op("sort_numeric",  "SELECT l_extendedprice FROM lineitem ORDER BY l_extendedprice"),
    op("sort_date",     "SELECT l_shipdate FROM lineitem ORDER BY l_shipdate"),
    op("sort_text",     "SELECT l_comment FROM lineitem ORDER BY l_comment",
       note="WARNING - HEAVIEST FILE IN THE SUITE: locale-aware text\n"
            "-- comparison, measured ~45s per run single-threaded (vs ~7s for\n"
            "-- the COLLATE \"C\" twin). A RUNS=10 sweep of this one file takes\n"
            "-- ~7 minutes; consider RUNS=2 or 3 here."),
    op("sort_text_collate_c",
       "SELECT l_comment FROM lineitem ORDER BY l_comment COLLATE \"C\"",
       note="Same data as sort_text with plain byte-wise comparison: the pair\n"
            "-- prices the collation itself."),
    op("sort_2_keys",
       "SELECT l_partkey, l_suppkey FROM lineitem ORDER BY l_partkey, l_suppkey"),
    op("sort_desc",     "SELECT l_partkey FROM lineitem ORDER BY l_partkey DESC"),
    op("sort_topn_100",
       "SELECT l_partkey FROM lineitem ORDER BY l_partkey LIMIT 100",
       note="LIMIT turns the full sort into a 100-element top-N heap: same\n"
            "-- input, a fraction of the work."),
    op("limit_with_ties",
       "SELECT l_partkey FROM lineitem ORDER BY l_partkey "
       "FETCH FIRST 100 ROWS WITH TIES",
       note="Limit in WITH TIES mode: returns the top 100 PLUS every row tied\n"
            "-- with the 100th on the sort key, so the Limit node keeps emitting\n"
            "-- past the count. Compare with sort_topn_100 (plain LIMIT)."),
]))

# ----------------------------------------------------------------- set operations
SPEC.append(("09_set_operations", "Set operations: two identical 1.5M-row branches",
 "Every file scans orders twice (o_custkey), so the branch cost is constant:\n"
 "-- 2 x scan_orders from 00_baseline. UNION ALL just appends; the other\n"
 "-- three add duplicate elimination / matching over the 3M combined rows.", [
    op("union_all",
       "SELECT o_custkey FROM orders UNION ALL SELECT o_custkey FROM orders",
       off=("indexonlyscan",)),
    op("union",
       "SELECT o_custkey FROM orders UNION SELECT o_custkey FROM orders",
       off=("indexonlyscan",),
       note="Dedups 3M rows down to ~100k distinct customers."),
    op("intersect",
       "SELECT o_custkey FROM orders INTERSECT SELECT o_custkey FROM orders",
       off=("indexonlyscan",)),
    op("except",
       "SELECT o_custkey FROM orders EXCEPT SELECT o_custkey FROM orders",
       off=("indexonlyscan",),
       note="Output is empty but the full matching work is still done."),
    op("intersect_all",
       "SELECT o_custkey FROM orders INTERSECT ALL SELECT o_custkey FROM orders",
       off=("indexonlyscan",),
       note="INTERSECT ALL keeps duplicates (min multiplicity per side), so the\n"
            "-- SetOp runs in ALL mode - no dedup - unlike plain intersect."),
    op("except_all",
       "SELECT o_custkey FROM orders EXCEPT ALL SELECT o_custkey FROM orders",
       off=("indexonlyscan",),
       note="EXCEPT ALL in SetOp ALL mode: pairs off duplicates rather than\n"
            "-- dropping them; compare with except (deduped)."),
]))

# ----------------------------------------------------------------- subqueries / CTEs
SPEC.append(("10_subqueries_ctes", "Query structure: derived tables, CTEs, correlation",
 "The first three files compute exactly scan_orders wrapped in different\n"
 "-- syntax: derived tables and single-use CTEs are inlined by the planner\n"
 "-- (PostgreSQL >= 12) and should measure the same as the bare scan, while\n"
 "-- AS MATERIALIZED forces a tuplestore write+read - that delta is the cost\n"
 "-- of materialization. The correlated files re-execute their subplan once\n"
 "-- per outer row.", [
    op("from_subquery",
       "SELECT sub.o_orderkey FROM (SELECT o_orderkey FROM orders) sub"),
    op("cte_inline",
       "WITH w AS (SELECT o_orderkey FROM orders) SELECT w.o_orderkey FROM w"),
    op("cte_materialized",
       "WITH w AS MATERIALIZED (SELECT o_orderkey FROM orders) "
       "SELECT w.o_orderkey FROM w"),
    op("scalar_uncorrelated",
       "SELECT (SELECT max(s_acctbal) FROM supplier) FROM orders",
       off=("indexonlyscan",),
       note="An InitPlan: the subquery runs ONCE, then 1.5M rows of constant."),
    op("scalar_correlated",
       "SELECT (SELECT n_name FROM nation WHERE n_nationkey = c_nationkey) "
       "FROM customer",
       off=("indexonlyscan",),
       note="150k executions of a 25-row seq scan: per-invocation SubPlan cost."),
    op("scalar_correlated_indexed",
       "SELECT (SELECT count(*) FROM orders o WHERE o.o_custkey = c.c_custkey) "
       "FROM customer c",
       note="150k correlated executions, each an idx_orders_cust probe + count."),
    op("lateral_limit",
       "SELECT ol.o_orderkey FROM customer c CROSS JOIN LATERAL "
       "(SELECT o.o_orderkey FROM orders o "
       "WHERE o.o_custkey = c.c_custkey LIMIT 5) ol",
       note="LATERAL with LIMIT inside: 150k index probes that each stop\n"
            "-- after 5 rows - the paginated-detail OLTP pattern."),
    op("cte_recursive",
       "WITH RECURSIVE t(n) AS ("
       "SELECT 1 UNION ALL SELECT n + 1 FROM t WHERE n < 1000000) "
       "SELECT n FROM t",
       note="Recursive CTE: Recursive Union feeding a WorkTable Scan, iterated\n"
            "-- 1M times. Touches no table - a pure read-only exercise of the\n"
            "-- recursive executor node (the only place WorkTable Scan appears)."),
    op("function_scan",
       "SELECT g FROM generate_series(1, 5000000) AS g",
       note="Function Scan: a set-returning function used as a table source\n"
            "-- (5M rows), distinct from a target-list SRF (ProjectSet, covered\n"
            "-- in Functions/09-26). Read-only, touches no table."),
    op("values_scan",
       "SELECT v FROM (VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10)) AS t(v)",
       note="Values Scan: an inline literal row set as a data source. Tiny by\n"
            "-- nature (node coverage) - its measurement is mostly no_table\n"
            "-- overhead."),
]))

# Parallelism used to be its own section here (the same work forced to 0/2/4
# workers). It is now a global runner knob instead: `make run WORKERS=N` caps
# max_parallel_workers_per_gather for the WHOLE suite via PGOPTIONS, so the
# time-vs-power trade can be swept across every query rather than a handful.
# WORKERS=0 is the fully-serial baseline; unset lets the planner decide.

# ----------------------------------------------------------------- 12 memory / work_mem
# The spill boundary. Each pair runs an IDENTICAL query at a small work_mem
# (forces an on-disk external algorithm) and a large one (stays in RAM). The
# delta is the energy cost of spilling to disk.
SPEC.append(("12_memory_workmem", "Memory pressure: on-disk spill vs in-RAM",
 "Each *_spill / *_nospill pair is the same query at work_mem 4MB vs 2GB.\n"
 "-- The plan node is identical; only Sort Method / Batches (in the plan)\n"
 "-- change between external-on-disk and in-memory.", [
    op("sort_spill", "SELECT l_partkey FROM lineitem ORDER BY l_partkey",
       sets=("work_mem = '4MB'",),
       note="6M-row sort at 4MB -> Sort Method: external merge (on disk)."),
    op("sort_nospill", "SELECT l_partkey FROM lineitem ORDER BY l_partkey",
       sets=("work_mem = '2GB'",),
       note="Same sort at 2GB -> Sort Method: quicksort (in memory)."),
    op("hashagg_spill", "SELECT l_partkey FROM lineitem GROUP BY l_partkey",
       sets=("work_mem = '4MB'",),
       note="200k groups at 4MB -> HashAggregate spills (Batches>1, Disk Usage;\n"
            "-- the PG13+ hash-aggregate disk spill)."),
    op("hashagg_nospill", "SELECT l_partkey FROM lineitem GROUP BY l_partkey",
       sets=("work_mem = '2GB'",),
       note="Same grouping at 2GB -> single in-memory hash table."),
    op("hashjoin_manybatch",
       "SELECT count(*) FROM orders o JOIN customer c ON o.o_custkey = c.c_custkey",
       off=("mergejoin", "nestloop"), sets=("work_mem = '1MB'",),
       note="Hash join build side split into many on-disk batches."),
    op("hashjoin_onebatch",
       "SELECT count(*) FROM orders o JOIN customer c ON o.o_custkey = c.c_custkey",
       off=("mergejoin", "nestloop"), sets=("work_mem = '1GB'",),
       note="Same hash join, single in-memory batch."),
    op("window_spill",
       "SELECT first_value(l_quantity) OVER (ORDER BY l_shipdate) FROM lineitem",
       sets=("work_mem = '4MB'",),
       note="The THIRD spill mechanism, distinct from sort and hashagg above: a\n"
            "-- WindowAgg buffers its whole partition in a tuplestore. With no\n"
            "-- PARTITION BY that is all 6M rows, which spills at 4MB. first_value\n"
            "-- reads the FRAME HEAD, so each row seeks a read pointer parked far\n"
            "-- behind the scan position - a disk seek per row (~31s at SF1)."),
    op("window_nospill",
       "SELECT first_value(l_quantity) OVER (ORDER BY l_shipdate) FROM lineitem",
       sets=("work_mem = '4GB'",),
       note="Same query with the tuplestore held in RAM: ~4s at SF1, i.e. the\n"
            "-- same cost as last_value/row_number. The ~8x delta against\n"
            "-- window_spill is the price of frame-head access on a spilled\n"
            "-- tuplestore - see Functions/09-22_window."),
    op("window_tail_spill",
       "SELECT last_value(l_quantity) OVER (ORDER BY l_shipdate) FROM lineitem",
       sets=("work_mem = '4MB'",),
       note="Control for window_spill: identical spilled tuplestore, but\n"
            "-- last_value reads the frame TAIL (at the current scan position,\n"
            "-- still buffered) so it stays ~4s. Spilling only hurts when the\n"
            "-- function reaches BACK into the frame."),
]))

# ----------------------------------------------------------------- 13 jit
# JIT compiles expression evaluation to machine code for expensive plans. It
# trades one-time compile energy for cheaper per-row evaluation. The query is
# arithmetic-heavy so JIT has something to compile. The files differ only in
# their JIT settings, so they plan identically (the planner-chosen worker count
# is the same across the series and cancels out); JIT is the only variable.
SPEC.append(("13_jit", "JIT: expression compilation on vs off",
 "Identical arithmetic-heavy scan; only the JIT settings differ. 'on' forces\n"
 "-- compilation (thresholds set to 0); progressively adds inlining then LLVM\n"
 "-- optimization. RAPL captures both the one-time compile energy and the\n"
 "-- changed per-row cost. On a scan-bound query the net effect is small -\n"
 "-- which is itself the finding. The plan's 'JIT:' block (function count and\n"
 "-- which optimizations ran) is printed in ./plans, so each file's settings\n"
 "-- can be confirmed to have taken effect.", [
    op("jit_off",
       "SELECT sum(sqrt(l_extendedprice::float8) + ln(l_quantity::float8 + 1) "
       "+ sin(l_discount::float8) + power(l_tax::float8 + 1, 3)) FROM lineitem",
       sets=("jit = off",),
       note="Baseline: interpreted expression evaluation, no compilation."),
    op("jit_on",
       "SELECT sum(sqrt(l_extendedprice::float8) + ln(l_quantity::float8 + 1) "
       "+ sin(l_discount::float8) + power(l_tax::float8 + 1, 3)) FROM lineitem",
       sets=("jit = on", "jit_above_cost = 0",
             "jit_inline_above_cost = -1", "jit_optimize_above_cost = -1"),
       note="Compile only (no inlining/optimization)."),
    op("jit_inline",
       "SELECT sum(sqrt(l_extendedprice::float8) + ln(l_quantity::float8 + 1) "
       "+ sin(l_discount::float8) + power(l_tax::float8 + 1, 3)) FROM lineitem",
       sets=("jit = on", "jit_above_cost = 0",
             "jit_inline_above_cost = 0", "jit_optimize_above_cost = -1"),
       note="Compile + inline small functions."),
    op("jit_optimize",
       "SELECT sum(sqrt(l_extendedprice::float8) + ln(l_quantity::float8 + 1) "
       "+ sin(l_discount::float8) + power(l_tax::float8 + 1, 3)) FROM lineitem",
       sets=("jit = on", "jit_above_cost = 0",
             "jit_inline_above_cost = 0", "jit_optimize_above_cost = 0"),
       note="Compile + inline + full LLVM optimization (most compile energy)."),
]))

# ----------------------------------------------------------------- 14 modern nodes
# Two execution nodes that only appear in specific shapes and are easy to miss:
# Incremental Sort (PG13, exploits a partially-sorted input) and Memoize (PG14,
# caches inner results of a parameterized nested loop).
SPEC.append(("14_modern_nodes", "Incremental Sort and Memoize (PG13/PG14)",
 "Each has an OFF sibling running the identical query with the node disabled,\n"
 "-- so the node's contribution is the difference.", [
    op("incremental_sort",
       "SELECT l_orderkey, l_linenumber FROM lineitem ORDER BY l_orderkey, l_linenumber",
       off=("seqscan",),
       note="Index supplies l_orderkey order; only l_linenumber is sorted\n"
            "-- within each key group -> Incremental Sort (Presorted Key)."),
    op("incremental_sort_off",
       "SELECT l_orderkey, l_linenumber FROM lineitem ORDER BY l_orderkey, l_linenumber",
       off=("seqscan", "incremental_sort"),
       note="Same query, incremental sort disabled -> one full 6M-row Sort."),
    op("memoize",
       "SELECT 1 FROM supplier s JOIN customer c ON c.c_nationkey = s.s_nationkey",
       off=("hashjoin", "mergejoin"),
       note="Nested loop probes customer via idx_customer_nation; only 25\n"
            "-- distinct nationkeys over 10k suppliers, so Memoize caches the\n"
            "-- inner scans (high Hit ratio)."),
    op("memoize_off",
       "SELECT 1 FROM supplier s JOIN customer c ON c.c_nationkey = s.s_nationkey",
       off=("hashjoin", "mergejoin", "memoize"),
       note="Same nested loop with the cache disabled: the inner index scan\n"
            "-- re-runs for every outer row."),
]))


def render(section_title, note, name, sql, off, sets, opnote):
    """Build the text of one .sql file."""
    lines = ["-- %s" % section_title, "-- Operation: %s" % name]
    if note:
        lines.append("-- " + note)
    if opnote:
        lines.append("-- " + opnote)
    lines.append("-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target")
    lines.append("-- list but discards rows server-side; every SET below is session-local to")
    lines.append("-- this psql invocation and vanishes when it exits.")
    # Worker count is never pinned here: it is left to the planner, or capped
    # for a whole sweep via the runner's WORKERS knob (make run WORKERS=N).
    for s in sets:
        lines.append("SET %s;" % s)
    for guc in off:
        lines.append("SET enable_%s = off;" % guc)
    lines.append(HEADER)
    lines.append(sql + ";")
    return "\n".join(lines) + "\n"


def main():
    if os.path.isdir(OUT_ROOT):
        shutil.rmtree(OUT_ROOT)
    total = 0
    for section_dir, title, note, ops in SPEC:
        d = os.path.join(OUT_ROOT, section_dir)
        os.makedirs(d, exist_ok=True)
        for name, sql, off, sets, opnote in ops:
            with open(os.path.join(d, name + ".sql"), "w") as fh:
                fh.write(render(title, note, name, sql, off, sets, opnote))
            total += 1
        print("%-26s %3d queries" % (section_dir, len(ops)))
    print("-" * 40)
    print("%-26s %3d queries" % ("TOTAL", total))


if __name__ == "__main__":
    main()
