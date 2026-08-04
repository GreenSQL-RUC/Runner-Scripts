-- Sorting 6M rows: key type, direction, top-N
-- Operation: limit_with_ties
-- Only the sort key is projected, so the files differ in comparator cost and
-- sorted-row width alone. At default work_mem these sorts spill to an
-- external merge on disk - that is the realistic case and is part of the
-- measurement.
-- Limit in WITH TIES mode: returns the top 100 PLUS every row tied
-- with the 100th on the sort key, so the Limit node keeps emitting
-- past the count. Compare with sort_topn_100 (plain LIMIT).
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT l_partkey FROM lineitem ORDER BY l_partkey FETCH FIRST 100 ROWS WITH TIES;
