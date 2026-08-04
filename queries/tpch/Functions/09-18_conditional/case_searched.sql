-- 9.18 Conditional Expressions
-- Operation: case_searched
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT CASE WHEN l_discount > 0.05 THEN 1 WHEN l_discount > 0.02 THEN 2 ELSE 3 END
FROM lineitem;
