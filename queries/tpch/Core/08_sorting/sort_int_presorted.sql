-- Sorting 6M rows: key type, direction, top-N
-- Operation: sort_int_presorted
-- Only the sort key is projected, so the files differ in comparator cost and
-- sorted-row width alone. At default work_mem these sorts spill to an
-- external merge on disk - that is the realistic case and is part of the
-- measurement.
-- The table is CLUSTERed on l_orderkey, so input arrives nearly
-- sorted: same Sort node as sort_int on friendlier data. Index
-- scans are pinned off - otherwise the planner reads the index
-- in order and drops the Sort node entirely.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET enable_indexscan = off;
SET enable_indexonlyscan = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT l_orderkey FROM lineitem ORDER BY l_orderkey;
