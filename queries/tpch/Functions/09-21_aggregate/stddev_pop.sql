-- 9.21 Aggregate Functions
-- Operation: stddev_pop
-- Aggregates collapse the table to one row, so unlike the projection queries
-- there is no per-row output to discard; the aggregate IS the operation here.
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT stddev_pop(l_discount) FROM lineitem;
