-- 9.21 Aggregate Functions
-- Operation: sum_filter
-- Aggregates collapse the table to one row, so unlike the projection queries
-- there is no per-row output to discard; the aggregate IS the operation here.
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT sum(l_quantity) FILTER (WHERE l_returnflag = 'R') FROM lineitem;
