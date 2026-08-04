-- 9.5 Binary String Functions and Operators
-- Operation: get_byte
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT get_byte(l_comment::bytea, 2)
FROM lineitem;
