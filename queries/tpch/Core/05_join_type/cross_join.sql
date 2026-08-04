-- Join semantics on one pair (planner free to choose)
-- Operation: cross_join
-- orders JOIN customer throughout (except cross/self), varying only the join
-- TYPE. Every file is pinned to a hash join over seq scans (same pins as
-- 04_join_scale), so the differences are purely what the semantics add:
-- outer-row emission, dedup for semi, full-side tracking, etc.
-- EXPANDS rows: 5 x 1.5M = 7.5M output. Kept small on purpose -
-- a cross join of two large tables would be pathological. A cross
-- join is always a nested loop, so only the scans are pinned.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET enable_indexonlyscan = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT 1 FROM region CROSS JOIN orders;
