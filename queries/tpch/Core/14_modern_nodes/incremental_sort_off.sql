-- Incremental Sort and Memoize (PG13/PG14)
-- Operation: incremental_sort_off
-- Each has an OFF sibling running the identical query with the node disabled,
-- so the node's contribution is the difference.
-- Same query, incremental sort disabled -> one full 6M-row Sort.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET enable_seqscan = off;
SET enable_incremental_sort = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT l_orderkey, l_linenumber FROM lineitem ORDER BY l_orderkey, l_linenumber;
