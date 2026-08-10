-- access methods: same rows, different scan node
-- OP: seq_scan

SET enable_seqscan = on;
SET enable_indexscan = off;
SET enable_bitmapscan = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT item_id FROM sales WHERE id BETWEEN 1 AND 30000;
