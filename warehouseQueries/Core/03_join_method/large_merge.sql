SET enable_hashjoin = off;
SET enable_nestloop = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT 1 FROM sales s JOIN items i ON s.item_id = i.item_id;