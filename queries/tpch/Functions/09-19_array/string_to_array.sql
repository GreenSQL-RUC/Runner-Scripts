-- 9.19 Array Functions and Operators
-- Operation: string_to_array
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT string_to_array(l_comment, ' ')
FROM lineitem;
