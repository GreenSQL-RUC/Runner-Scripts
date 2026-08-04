-- Access methods: same rows, different scan node
-- Operation: index_point_lookup
-- All range queries fetch the same ~600k rows (~10% of lineitem) via
-- l_orderkey BETWEEN 1 AND 600000, so the files differ only in the scan
-- node used. The table is CLUSTERed on l_orderkey, so the index reads
-- contiguous heap pages - this is the friendly case for index scans.
-- A single-key probe (a few rows): the OLTP access pattern. Almost
-- all of its measurement is the fixed no_table overhead.
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET enable_seqscan = off;
SET enable_bitmapscan = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT l_partkey FROM lineitem WHERE l_orderkey = 3000000;
