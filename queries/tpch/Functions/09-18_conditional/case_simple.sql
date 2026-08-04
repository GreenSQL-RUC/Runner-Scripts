-- 9.18 Conditional Expressions
-- Operation: case_simple
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT CASE l_returnflag WHEN 'A' THEN 1 WHEN 'R' THEN 2 ELSE 3 END
FROM lineitem;
