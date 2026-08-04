-- Sorting 6M rows: key type, direction, top-N
-- Operation: sort_topn_100
-- Only the sort key is projected, so the files differ in comparator cost and
-- sorted-row width alone. At default work_mem these sorts spill to an
-- external merge on disk - that is the realistic case and is part of the
-- measurement.
-- LIMIT turns the full sort into a 100-element top-N heap: same
-- input, a fraction of the work.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT l_partkey FROM lineitem ORDER BY l_partkey LIMIT 100;
