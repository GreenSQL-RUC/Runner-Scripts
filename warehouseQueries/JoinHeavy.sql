-- tests join algorithm choice (memory for hash joins)
SELECT sup.supplier_name, SUM(s.retail_sales) AS total_retail
FROM sales s
JOIN suppliers sup ON sup.supplier_id = s.supplier_id
GROUP BY sup.supplier_name
ORDER BY total_retail DESC
LIMIT 20;