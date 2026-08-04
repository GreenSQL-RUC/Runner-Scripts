-- Memory pressure: on-disk spill vs in-RAM
-- Operation: window_spill
-- Each *_spill / *_nospill pair is the same query at work_mem 4MB vs 2GB.
-- The plan node is identical; only Sort Method / Batches (in the plan)
-- change between external-on-disk and in-memory.
-- The THIRD spill mechanism, distinct from sort and hashagg above: a
-- WindowAgg buffers its whole partition in a tuplestore. With no
-- PARTITION BY that is all 6M rows, which spills at 4MB. first_value
-- reads the FRAME HEAD, so each row seeks a read pointer parked far
-- behind the scan position - a disk seek per row (~31s at SF1).
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET work_mem = '4MB';
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT first_value(l_quantity) OVER (ORDER BY l_shipdate) FROM lineitem;
