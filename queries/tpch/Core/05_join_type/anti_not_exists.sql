-- Join semantics on one pair (planner free to choose)
-- Operation: anti_not_exists
-- orders JOIN customer throughout (except cross/self), varying only the join
-- TYPE. Every file is pinned to a hash join over seq scans (same pins as
-- 04_join_scale), so the differences are purely what the semantics add:
-- outer-row emission, dedup for semi, full-side tracking, etc.
-- Hash Anti Join, same probe work as semi_exists but emitting the
-- NON-matches (none here: every order has a customer, output 0).
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET enable_mergejoin = off;
SET enable_nestloop = off;
SET enable_indexonlyscan = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT 1 FROM orders o WHERE NOT EXISTS (SELECT 1 FROM customer c WHERE c.c_custkey = o.o_custkey);
