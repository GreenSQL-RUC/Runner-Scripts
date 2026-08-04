-- 9.16 JSON Functions and Operators
-- Operation: jsonb_insert
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT jsonb_insert(jsonb_build_object('k', l_orderkey), '{n}', '"x"')
FROM lineitem;
