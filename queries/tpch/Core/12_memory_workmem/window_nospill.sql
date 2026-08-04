-- Memory pressure: on-disk spill vs in-RAM
-- Operation: window_nospill
-- Each *_spill / *_nospill pair is the same query at work_mem 4MB vs 2GB.
-- The plan node is identical; only Sort Method / Batches (in the plan)
-- change between external-on-disk and in-memory.
-- Same query with the tuplestore held in RAM: ~4s at SF1, i.e. the
-- same cost as last_value/row_number. The ~8x delta against
-- window_spill is the price of frame-head access on a spilled
-- tuplestore - see Functions/09-22_window.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET work_mem = '4GB';
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT first_value(l_quantity) OVER (ORDER BY l_shipdate) FROM lineitem;
