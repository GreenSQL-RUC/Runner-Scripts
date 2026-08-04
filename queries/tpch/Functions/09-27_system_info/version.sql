-- 9.27 System Information Functions and Operators
-- Operation: version
-- Functions marked stable (version(), current_database(), ...) are evaluated
-- once for the whole query rather than per row, so they measure close to the
-- baseline by design; pg_column_size and pg_typeof are the per-row ones.
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT version()
FROM lineitem;
