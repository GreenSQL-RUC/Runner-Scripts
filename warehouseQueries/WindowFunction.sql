-- tests sort/partition memory, distinct from simple aggregation
SELECT item_type, sale_month, SUM(warehouse_sales) AS monthly_total, 
       SUM(SUM(warehouse_sales)) OVER (PARTITION BY item_type ORDER BY sale_month) AS running_total
FROM sales
GROUP BY item_type, sale_month
ORDER BY item_type, sale_month;       