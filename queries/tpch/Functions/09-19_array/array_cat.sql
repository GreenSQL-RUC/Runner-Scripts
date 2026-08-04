-- 9.19 Array Functions and Operators
-- Operation: array_cat
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT array_cat(ARRAY[l_orderkey], ARRAY[l_partkey])
FROM lineitem;
