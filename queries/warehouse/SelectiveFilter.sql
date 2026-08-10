-- index-friendly, low cardinality result. Tests planner's index v seq scan choice
-- MUST run this command before running files with index:  psql -d warehouse -p 5432 -c "CREATE INDEX idx_sales_id ON sales(id);"
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT i.item_description, s.warehouse_sales
FROM sales s
JOIN items i ON i.item_id = s.item_id
WHERE i.item_type = 'KEGS' AND s.sale_month = 6;
