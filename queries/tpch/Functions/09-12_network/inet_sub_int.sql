-- 9.12 Network Address Functions and Operators
-- Operation: inet_sub_int
-- Addresses are synthesised from l_orderkey; nothing is stored.
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT ('10.0.0.1'::inet + (l_orderkey % 16777216)) - 1
FROM lineitem;
