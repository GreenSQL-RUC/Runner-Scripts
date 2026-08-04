-- 9.8 Data Type Formatting Functions
-- Operation: to_number
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT to_number(to_char(l_extendedprice, '9999999D99'), '9999999D99')
FROM lineitem;
