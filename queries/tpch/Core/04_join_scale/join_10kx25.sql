-- Join cost vs input size (hash join forced)
-- Operation: join_10kx25
-- The same many-to-one key join at every size the schema offers, all forced
-- to hash join so the numbers form one comparable series. File names give
-- outer x inner input sizes; output rows = outer rows for each. Subtract
-- the two input scans (00_baseline) to get the join-node cost alone.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET enable_mergejoin = off;
SET enable_nestloop = off;
SET enable_indexonlyscan = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT 1 FROM supplier s JOIN nation n ON s.s_nationkey = n.n_nationkey;
