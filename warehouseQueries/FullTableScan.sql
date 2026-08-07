-- I/O as CPU heavy (full table scane/aggregation)
SELECT item_type, SUM(warehouse_sales) AS total_warehouse
FROM sales
GROUP BY item_type
ORDER BY total_warehouse DESC;