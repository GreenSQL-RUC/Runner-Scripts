-- 9.15 XML Functions
-- Operation: xmlconcat
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT xmlconcat(xmlelement(name a, l_orderkey), xmlelement(name b, l_comment))
FROM lineitem;
