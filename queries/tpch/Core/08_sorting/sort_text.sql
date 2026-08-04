-- Sorting 6M rows: key type, direction, top-N
-- Operation: sort_text
-- Only the sort key is projected, so the files differ in comparator cost and
-- sorted-row width alone. At default work_mem these sorts spill to an
-- external merge on disk - that is the realistic case and is part of the
-- measurement.
-- WARNING - HEAVIEST FILE IN THE SUITE: locale-aware text
-- comparison, measured ~45s per run single-threaded (vs ~7s for
-- the COLLATE "C" twin). A RUNS=10 sweep of this one file takes
-- ~7 minutes; consider RUNS=2 or 3 here.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT l_comment FROM lineitem ORDER BY l_comment;
