-- 9.20 Range/Multirange Functions and Operators
-- Operation: contains_range
-- least()/greatest() guard the constructor: a range whose lower bound exceeds
-- its upper bound raises an error.
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT daterange(least(l_shipdate, l_receiptdate), greatest(l_shipdate, l_receiptdate), '[]') @> daterange(DATE '1995-06-15', DATE '1995-06-16')
FROM lineitem;
