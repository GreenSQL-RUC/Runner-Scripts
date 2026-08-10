-- chain joins: sales ->  items
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT sup.supplier_name, i.item_type, s.warehouse_sales
FROM sales s
JOIN suppliers sup ON s.supplier_id = sup.supplier_id
JOIN items i ON s.item_id = i.item_id;