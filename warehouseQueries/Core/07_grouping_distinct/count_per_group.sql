EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT item_type, count(*) FROM sales s JOIN items i ON s.item_id = i.item_id GROUP BY item_type;