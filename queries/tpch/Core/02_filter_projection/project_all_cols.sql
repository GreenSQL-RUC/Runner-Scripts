-- Filter selectivity and projection width
-- Operation: project_all_cols
-- l_quantity is uniform on 1..50, so the filter series passes ~0%, ~2%, ~50%
-- and 100% of the 6M rows while evaluating the same predicate on every row:
-- the difference between the files is the cost of EMITTING rows, the
-- difference from scan_lineitem is the predicate itself. The projection
-- pair varies only the width of the target list.
-- All 16 columns: compare with scan_lineitem (1 column) for the
-- cost of target-list width.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT * FROM lineitem;
