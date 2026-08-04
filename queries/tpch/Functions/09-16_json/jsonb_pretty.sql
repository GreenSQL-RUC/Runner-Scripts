-- 9.16 JSON Functions and Operators
-- Operation: jsonb_pretty
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT jsonb_pretty(jsonb_build_object('k', l_orderkey, 'c', l_comment))
FROM lineitem;
