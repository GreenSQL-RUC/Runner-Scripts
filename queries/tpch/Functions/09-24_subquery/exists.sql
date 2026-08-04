-- 9.24 Subquery Expressions
-- Operation: exists
-- These take the WHERE-clause form because that is how subquery expressions are
-- actually used; the planner turns most of them into semi/anti-joins.
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT 1 FROM lineitem l WHERE EXISTS (SELECT 1 FROM orders o WHERE o.o_orderkey = l.l_orderkey);
