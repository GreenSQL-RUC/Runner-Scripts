-- Grouping and duplicate elimination
-- Operation: group_7_vals
-- Bare GROUP BY (no aggregate) isolates the grouping machinery itself; the
-- group-count series varies only the number of groups the hash table must
-- hold (3 -> 7 -> 200k -> 1.5M) over the same 6M input rows. Aggregate
-- FUNCTION costs live in Functions/09-21_aggregate.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT l_shipmode FROM lineitem GROUP BY l_shipmode;
