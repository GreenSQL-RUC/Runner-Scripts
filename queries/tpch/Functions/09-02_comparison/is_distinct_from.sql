-- 9.2 Comparison Functions and Operators
-- Operation: is_distinct_from
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT l_quantity IS DISTINCT FROM 30
FROM lineitem;
