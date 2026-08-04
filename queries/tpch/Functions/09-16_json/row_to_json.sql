-- 9.16 JSON Functions and Operators
-- Operation: row_to_json
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT row_to_json(row(l_orderkey, l_comment))
FROM lineitem;
