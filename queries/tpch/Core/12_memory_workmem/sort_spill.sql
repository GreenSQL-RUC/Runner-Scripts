-- Memory pressure: on-disk spill vs in-RAM
-- Operation: sort_spill
-- Each *_spill / *_nospill pair is the same query at work_mem 4MB vs 2GB.
-- The plan node is identical; only Sort Method / Batches (in the plan)
-- change between external-on-disk and in-memory.
-- 6M-row sort at 4MB -> Sort Method: external merge (on disk).
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET work_mem = '4MB';
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT l_partkey FROM lineitem ORDER BY l_partkey;
