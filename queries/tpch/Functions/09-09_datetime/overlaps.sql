-- 9.9 Date/Time Functions and Operators
-- Operation: overlaps
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT (l_shipdate, l_receiptdate) OVERLAPS (DATE '1995-01-01', DATE '1995-12-31')
FROM lineitem;
