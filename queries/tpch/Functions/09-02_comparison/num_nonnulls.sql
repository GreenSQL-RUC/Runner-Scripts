-- 9.2 Comparison Functions and Operators
-- Operation: num_nonnulls
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT num_nonnulls(l_quantity, l_extendedprice)
FROM lineitem;
