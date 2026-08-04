-- Grouping and duplicate elimination
-- Operation: group_1500k_vals
-- Bare GROUP BY (no aggregate) isolates the grouping machinery itself; the
-- group-count series varies only the number of groups the hash table must
-- hold (3 -> 7 -> 200k -> 1.5M) over the same 6M input rows. Aggregate
-- FUNCTION costs live in Functions/09-21_aggregate.
-- Index scans pinned off: l_orderkey is indexed and the planner
-- would otherwise group pre-ordered index output, leaving the
-- series. At 1.5M groups the hash table exceeds work_mem and
-- spills - that cliff is part of what this file measures.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET enable_indexscan = off;
SET enable_indexonlyscan = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT l_orderkey FROM lineitem GROUP BY l_orderkey;
