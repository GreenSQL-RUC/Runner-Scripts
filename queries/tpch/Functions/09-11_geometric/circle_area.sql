-- 9.11 Geometric Functions and Operators
-- Operation: circle_area
-- Geometry is synthesised from numeric columns; nothing is stored.
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT area(circle(point(l_quantity::float8, l_tax::float8), 2))
FROM lineitem;
