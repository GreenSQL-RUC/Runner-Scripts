-- tests join algorithm choice (memory for hash joins)
SELECT sup.suppler_name, SUM(s.retail_sales) AS total_retail
FROM sales s
JOIN suppliers sup ON sup.suppler_id = s.suppler_id
GROUP BY sup.suppler_name
ORDER BY total_retail DESC
LIMIT 20;