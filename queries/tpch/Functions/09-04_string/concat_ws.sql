-- 9.4 String Functions and Operators
-- Operation: concat_ws
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT concat_ws('-', l_comment, l_shipmode)
FROM lineitem;
