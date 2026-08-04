-- Query structure: derived tables, CTEs, correlation
-- Operation: lateral_limit
-- The first three files compute exactly scan_orders wrapped in different
-- syntax: derived tables and single-use CTEs are inlined by the planner
-- (PostgreSQL >= 12) and should measure the same as the bare scan, while
-- AS MATERIALIZED forces a tuplestore write+read - that delta is the cost
-- of materialization. The correlated files re-execute their subplan once
-- per outer row.
-- LATERAL with LIMIT inside: 150k index probes that each stop
-- after 5 rows - the paginated-detail OLTP pattern.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT ol.o_orderkey FROM customer c CROSS JOIN LATERAL (SELECT o.o_orderkey FROM orders o WHERE o.o_custkey = c.c_custkey LIMIT 5) ol;
