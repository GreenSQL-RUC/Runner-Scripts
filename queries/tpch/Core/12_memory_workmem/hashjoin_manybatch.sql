-- Memory pressure: on-disk spill vs in-RAM
-- Operation: hashjoin_manybatch
-- Each *_spill / *_nospill pair is the same query at work_mem 4MB vs 2GB.
-- The plan node is identical; only Sort Method / Batches (in the plan)
-- change between external-on-disk and in-memory.
-- Hash join build side split into many on-disk batches.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET work_mem = '1MB';
SET enable_mergejoin = off;
SET enable_nestloop = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT count(*) FROM orders o JOIN customer c ON o.o_custkey = c.c_custkey;
