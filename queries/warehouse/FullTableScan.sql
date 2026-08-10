-- I/O as CPU heavy (full table scan/aggregation)
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT item_id, SUM(warehouse_sales) AS total_warehouse
FROM sales
GROUP BY item_id
ORDER BY total_warehouse DESC;
