-- 9.9 Date/Time Functions and Operators
-- Operation: date_bin
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT date_bin(INTERVAL '7 days', l_shipdate::timestamp, TIMESTAMP '1992-01-01')
FROM lineitem;
