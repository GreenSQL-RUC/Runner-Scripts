-- Incremental Sort and Memoize (PG13/PG14)
-- Operation: memoize
-- Each has an OFF sibling running the identical query with the node disabled,
-- so the node's contribution is the difference.
-- Nested loop probes customer via idx_customer_nation; only 25
-- distinct nationkeys over 10k suppliers, so Memoize caches the
-- inner scans (high Hit ratio).
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET enable_hashjoin = off;
SET enable_mergejoin = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT 1 FROM supplier s JOIN customer c ON c.c_nationkey = s.s_nationkey;
