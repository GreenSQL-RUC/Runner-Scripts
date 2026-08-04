-- 9.16 JSON Functions and Operators
-- Operation: jsonb_object_keys_arr
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT (SELECT array_agg(k) FROM jsonb_object_keys(jsonb_build_object('k', l_orderkey, 'c', l_comment)) AS k)
FROM lineitem;
