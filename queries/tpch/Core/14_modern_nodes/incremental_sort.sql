-- Incremental Sort and Memoize (PG13/PG14)
-- Operation: incremental_sort
-- Each has an OFF sibling running the identical query with the node disabled,
-- so the node's contribution is the difference.
-- Index supplies l_orderkey order; only l_linenumber is sorted
-- within each key group -> Incremental Sort (Presorted Key).
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET enable_seqscan = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT l_orderkey, l_linenumber FROM lineitem ORDER BY l_orderkey, l_linenumber;
