-- Access methods: same rows, different scan node
-- Operation: bitmap_scan
-- All range queries fetch the same ~600k rows (~10% of lineitem) via
-- l_orderkey BETWEEN 1 AND 600000, so the files differ only in the scan
-- node used. The table is CLUSTERed on l_orderkey, so the index reads
-- contiguous heap pages - this is the friendly case for index scans.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET enable_seqscan = off;
SET enable_indexscan = off;
SET enable_indexonlyscan = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT l_partkey FROM lineitem WHERE l_orderkey BETWEEN 1 AND 600000;
