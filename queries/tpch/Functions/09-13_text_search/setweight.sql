-- 9.13 Text Search Functions and Operators
-- Operation: setweight
-- WARNING: the heaviest section. Parsing each row into a tsvector with no index
-- costs roughly 25s per run over the full 6M rows, so a RUNS=10 sweep of this
-- directory alone takes a long time. Consider RUNS=2 or 3 here.
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT setweight(to_tsvector('english', l_comment), 'A')
FROM lineitem;
