-- 9.8 Data Type Formatting Functions
-- Operation: to_char_int
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT to_char(l_orderkey, '9999999')
FROM lineitem;
