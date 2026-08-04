-- Memory pressure: on-disk spill vs in-RAM
-- Operation: hashagg_nospill
-- Each *_spill / *_nospill pair is the same query at work_mem 4MB vs 2GB.
-- The plan node is identical; only Sort Method / Batches (in the plan)
-- change between external-on-disk and in-memory.
-- Same grouping at 2GB -> single in-memory hash table.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET work_mem = '2GB';
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT l_partkey FROM lineitem GROUP BY l_partkey;
