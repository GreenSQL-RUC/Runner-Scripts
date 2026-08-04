-- Query structure: derived tables, CTEs, correlation
-- Operation: values_scan
-- The first three files compute exactly scan_orders wrapped in different
-- syntax: derived tables and single-use CTEs are inlined by the planner
-- (PostgreSQL >= 12) and should measure the same as the bare scan, while
-- AS MATERIALIZED forces a tuplestore write+read - that delta is the cost
-- of materialization. The correlated files re-execute their subplan once
-- per outer row.
-- Values Scan: an inline literal row set as a data source. Tiny by
-- nature (node coverage) - its measurement is mostly no_table
-- overhead.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT v FROM (VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10)) AS t(v);
