-- 9.9 Date/Time Functions and Operators
-- Operation: age_two_args
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT age(l_receiptdate, l_shipdate)
FROM lineitem;
