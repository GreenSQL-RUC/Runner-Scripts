-- Set operations: two identical 1.5M-row branches
-- Operation: intersect
-- Every file scans orders twice (o_custkey), so the branch cost is constant:
-- 2 x scan_orders from 00_baseline. UNION ALL just appends; the other
-- three add duplicate elimination / matching over the 3M combined rows.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET enable_indexonlyscan = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT o_custkey FROM orders INTERSECT SELECT o_custkey FROM orders;
