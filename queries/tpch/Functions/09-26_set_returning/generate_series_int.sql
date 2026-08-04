-- 9.26 Set Returning Functions
-- Operation: generate_series_int
-- Unlike every other section these EXPAND the row count (each input row yields
-- many), so they are comparable with each other but not with the projection
-- queries elsewhere.
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT generate_series(1, l_linenumber)
FROM lineitem;
