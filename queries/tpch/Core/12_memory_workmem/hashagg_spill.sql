-- Memory pressure: on-disk spill vs in-RAM
-- Operation: hashagg_spill
-- Each *_spill / *_nospill pair is the same query at work_mem 4MB vs 2GB.
-- The plan node is identical; only Sort Method / Batches (in the plan)
-- change between external-on-disk and in-memory.
-- 200k groups at 4MB -> HashAggregate spills (Batches>1, Disk Usage;
-- the PG13+ hash-aggregate disk spill).
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET work_mem = '4MB';
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT l_partkey FROM lineitem GROUP BY l_partkey;
