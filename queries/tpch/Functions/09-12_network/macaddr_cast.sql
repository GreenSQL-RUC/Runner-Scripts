-- 9.12 Network Address Functions and Operators
-- Operation: macaddr_cast
-- Addresses are synthesised from l_orderkey; nothing is stored.
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT to_hex(l_orderkey % 16777216)
FROM lineitem;
