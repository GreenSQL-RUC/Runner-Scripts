-- Grouping and duplicate elimination
-- Operation: distinct_on
-- Bare GROUP BY (no aggregate) isolates the grouping machinery itself; the
-- group-count series varies only the number of groups the hash table must
-- hold (3 -> 7 -> 200k -> 1.5M) over the same 6M input rows. Aggregate
-- FUNCTION costs live in Functions/09-21_aggregate.
-- Includes the mandatory 6M-row sort, which dominates.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT DISTINCT ON (l_returnflag) l_returnflag, l_shipdate FROM lineitem ORDER BY l_returnflag, l_shipdate;
