-- closer to tpc-h multi-table join
SELECT sup.supplier_name, i.item_type, SUM(s.retail_transfers) AS total_transfers
FROM sales s
JOIN suppliers sup ON sup.supplier_id = s.supplier_id
JOIN items i ON i.item_id = s.item_id
GROUP BY sup.supplier_name, i.item_type
HAVING SUM(s.retail_transfers) < 0
ORDER BY total_transfers ASC
LIMIT 15;