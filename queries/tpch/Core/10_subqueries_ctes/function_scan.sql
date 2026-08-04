-- Query structure: derived tables, CTEs, correlation
-- Operation: function_scan
-- The first three files compute exactly scan_orders wrapped in different
-- syntax: derived tables and single-use CTEs are inlined by the planner
-- (PostgreSQL >= 12) and should measure the same as the bare scan, while
-- AS MATERIALIZED forces a tuplestore write+read - that delta is the cost
-- of materialization. The correlated files re-execute their subplan once
-- per outer row.
-- Function Scan: a set-returning function used as a table source
-- (5M rows), distinct from a target-list SRF (ProjectSet, covered
-- in Functions/09-26). Read-only, touches no table.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT g FROM generate_series(1, 5000000) AS g;
