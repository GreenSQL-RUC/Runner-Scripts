-- Baselines: one seq scan per table
-- Operation: scan_lineitem
-- Subtract the scan cost of an operator's input table(s) from its measurement
-- to isolate the operator itself (a join reads two tables: subtract both).
-- no_table measures the fixed per-run overhead every file pays: psql
-- startup, parse/plan, EXPLAIN machinery. Narrowest int column projected
-- so the target list adds as little as possible.
-- l_orderkey is indexed, so the index-only scan is pinned off to
-- keep this the SEQ SCAN baseline the other sections subtract.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET enable_indexonlyscan = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT l_orderkey FROM lineitem;
