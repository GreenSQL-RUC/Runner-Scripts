-- I/O as CPU heavy (full table scan/aggregation)
SELECT item_id, SUM(warehouse_sales) AS total_warehouse
FROM sales
GROUP BY item_id
ORDER BY total_warehouse DESC;