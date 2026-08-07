-- make sure to have created index 
SET enable_seqscan SET enable_seqscan = off;
SET enable_indexscan = on;
SET enable_bitmapscan = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT item_id FROM sales WHERE id BETWEEN 1 AND 30000;