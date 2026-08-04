-- Query structure: derived tables, CTEs, correlation
-- Operation: from_subquery
-- The first three files compute exactly scan_orders wrapped in different
-- syntax: derived tables and single-use CTEs are inlined by the planner
-- (PostgreSQL >= 12) and should measure the same as the bare scan, while
-- AS MATERIALIZED forces a tuplestore write+read - that delta is the cost
-- of materialization. The correlated files re-execute their subplan once
-- per outer row.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT sub.o_orderkey FROM (SELECT o_orderkey FROM orders) sub;
