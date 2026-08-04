-- Join semantics on one pair (planner free to choose)
-- Operation: self_join
-- orders JOIN customer throughout (except cross/self), varying only the join
-- TYPE. Every file is pinned to a hash join over seq scans (same pins as
-- 04_join_scale), so the differences are purely what the semantics add:
-- outer-row emission, dedup for semi, full-side tracking, etc.
-- Same table on both sides (1.5M x 1.5M on the key, output 1.5M):
-- compare with join_1500kx150k for the effect of build-side size.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET enable_mergejoin = off;
SET enable_nestloop = off;
SET enable_indexonlyscan = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT 1 FROM orders o1 JOIN orders o2 ON o1.o_orderkey = o2.o_orderkey;
