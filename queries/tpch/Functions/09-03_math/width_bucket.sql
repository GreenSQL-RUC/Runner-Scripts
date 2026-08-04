-- 9.3 Mathematical Functions and Operators
-- Operation: width_bucket
-- Several operations appear in both a numeric and a float8 variant: numeric is
-- arbitrary-precision software arithmetic, float8 is hardware, so the pair
-- shows the energy cost of the type choice for the same operation.
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT width_bucket(l_quantity, 0, 50, 10)
FROM lineitem;
