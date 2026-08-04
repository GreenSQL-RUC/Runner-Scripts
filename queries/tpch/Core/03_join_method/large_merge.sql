-- Join methods: same join, forced algorithm
-- Operation: large_merge
-- Each trio computes the IDENTICAL join with a different algorithm, forced by
-- disabling the other methods. large_* = orders JOIN customer (1.5M x 150k,
-- output 1.5M rows); small_* = supplier JOIN nation (10k x 25, output 10k).
-- Subtract the two input-table scans from 00_baseline to isolate the join.
-- No unindexed nestloop on the large pair: 1.5M x 150k row comparisons is
-- pathological (hours). The indexed variant probes orders(o_custkey) instead.
-- Index scans pinned off too, so this is the canonical sort + sort
-- + merge (otherwise the planner reads orders pre-ordered via
-- idx_orders_cust and skips one sort).
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET enable_hashjoin = off;
SET enable_nestloop = off;
SET enable_indexscan = off;
SET enable_indexonlyscan = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT 1 FROM orders o JOIN customer c ON o.o_custkey = c.c_custkey;
