-- 9.6 Bit String Functions and Operators
-- Operation: overlay_bit
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT overlay(l_orderkey::bit(32) PLACING b'11' FROM 2)
FROM lineitem;
