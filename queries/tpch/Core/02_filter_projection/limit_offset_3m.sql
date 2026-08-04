-- Filter selectivity and projection width
-- Operation: limit_offset_3m
-- l_quantity is uniform on 1..50, so the filter series passes ~0%, ~2%, ~50%
-- and 100% of the 6M rows while evaluating the same predicate on every row:
-- the difference between the files is the cost of EMITTING rows, the
-- difference from scan_lineitem is the predicate itself. The projection
-- pair varies only the width of the target list.
-- OFFSET rows are fully fetched and discarded: half the scan cost
-- despite returning 100 rows.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET enable_indexonlyscan = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT l_orderkey FROM lineitem LIMIT 100 OFFSET 3000000;
