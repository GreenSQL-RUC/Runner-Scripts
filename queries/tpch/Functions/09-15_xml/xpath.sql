-- 9.15 XML Functions
-- Operation: xpath
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT xpath('/item/text()', xmlelement(name item, l_comment))
FROM lineitem;
