-- Baselines (no Chapter 9 operation applied)
-- Operation: int
-- Subtract the baseline whose input column type matches the query under test:
-- scanning a wide text column costs more than a narrow int, so comparing a
-- numeric operation against the text baseline can make it look free.
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT l_orderkey
FROM lineitem;
