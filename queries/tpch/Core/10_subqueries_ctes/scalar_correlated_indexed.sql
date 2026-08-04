-- Query structure: derived tables, CTEs, correlation
-- Operation: scalar_correlated_indexed
-- The first three files compute exactly scan_orders wrapped in different
-- syntax: derived tables and single-use CTEs are inlined by the planner
-- (PostgreSQL >= 12) and should measure the same as the bare scan, while
-- AS MATERIALIZED forces a tuplestore write+read - that delta is the cost
-- of materialization. The correlated files re-execute their subplan once
-- per outer row.
-- 150k correlated executions, each an idx_orders_cust probe + count.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT (SELECT count(*) FROM orders o WHERE o.o_custkey = c.c_custkey) FROM customer c;
