-- Join-count scaling per join method: 1 to 4 joins
-- Operation: chain_3_nestloop
-- Three parallel series - hash / merge / nestloop - each add one many-to-one
-- join at a time, all preserving the 6M-row output. Within a series the
-- consecutive difference (chain_N vs chain_N-1) is the incremental cost of
-- join N, and the chain_1 -> chain_4 slope is that method's scaling curve.
-- Only the join METHOD is forced (the other two are disabled); scans, sorts
-- and parallelism are the planner's choice, so each method runs in its
-- natural form. The scan nodes therefore differ BETWEEN methods (nestloop
-- probes indexes; hash builds hash tables; merge sorts inputs), so compare
-- the scaling SHAPE across methods, not raw cross-method deltas. nestloop
-- stays feasible only because the added tables are reachable by index
-- (idx_lineitem_order / idx_orders_cust / idx_customer_nation) when the
-- planner drives from the small end (region -> ... -> lineitem); without
-- those indexes a forced nestloop chain would be pathological.
-- Nestloop join, 3-join chain (lineitem -> orders -> customer -> nation).
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET enable_hashjoin = off;
SET enable_mergejoin = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT 1 FROM lineitem l JOIN orders o ON l.l_orderkey = o.o_orderkey JOIN customer c ON o.o_custkey = c.c_custkey JOIN nation n ON c.c_nationkey = n.n_nationkey;
