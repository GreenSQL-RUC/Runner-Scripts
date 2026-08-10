SET enable_hashjoin = off;
SET enable_nestloop = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT 1 FROM fact_capital_stock f JOIN dim_geo g ON f.geo_id = g.geo_id;