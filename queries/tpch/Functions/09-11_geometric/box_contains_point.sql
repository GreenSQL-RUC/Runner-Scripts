-- 9.11 Geometric Functions and Operators
-- Operation: box_contains_point
-- Geometry is synthesised from numeric columns; nothing is stored.
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT box(point(0, 0), point(l_quantity::float8 + 1, l_tax::float8 + 1)) @> point(1, 0.5)
FROM lineitem;
