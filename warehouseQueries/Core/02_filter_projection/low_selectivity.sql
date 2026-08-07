EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT id FROM sales s JOIN items i On s.item_id = i.item_id WHERE i.item_type = 'Liquor';