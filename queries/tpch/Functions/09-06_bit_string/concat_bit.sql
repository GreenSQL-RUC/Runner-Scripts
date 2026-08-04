-- 9.6 Bit String Functions and Operators
-- Operation: concat_bit
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT l_orderkey::bit(32) || l_linenumber::bit(8)
FROM lineitem;
