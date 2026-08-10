EXPLAIN  (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT geo_id, count(*) FROM fact_capital_stock GROUP BY geo_id;