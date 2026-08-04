-- 9.25 Row and Array Comparisons
-- Operation: row_is_distinct
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT (l_returnflag, l_linestatus) IS DISTINCT FROM ('A', 'F')
FROM lineitem;
