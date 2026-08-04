-- Incremental Sort and Memoize (PG13/PG14)
-- Operation: memoize_off
-- Each has an OFF sibling running the identical query with the node disabled,
-- so the node's contribution is the difference.
-- Same nested loop with the cache disabled: the inner index scan
-- re-runs for every outer row.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET enable_hashjoin = off;
SET enable_mergejoin = off;
SET enable_memoize = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT 1 FROM supplier s JOIN customer c ON c.c_nationkey = s.s_nationkey;
