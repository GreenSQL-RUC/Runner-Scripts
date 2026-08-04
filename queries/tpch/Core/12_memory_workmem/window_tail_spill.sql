-- Memory pressure: on-disk spill vs in-RAM
-- Operation: window_tail_spill
-- Each *_spill / *_nospill pair is the same query at work_mem 4MB vs 2GB.
-- The plan node is identical; only Sort Method / Batches (in the plan)
-- change between external-on-disk and in-memory.
-- Control for window_spill: identical spilled tuplestore, but
-- last_value reads the frame TAIL (at the current scan position,
-- still buffered) so it stays ~4s. Spilling only hurts when the
-- function reaches BACK into the frame.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET work_mem = '4MB';
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT last_value(l_quantity) OVER (ORDER BY l_shipdate) FROM lineitem;
