-- Chain join across all 5 dimensions - the real "star schema" query shape

EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT g.geo_code, u.unit_code, n.nace_code, a.asset_code, ni.na_item_code, f.year, f.value
FROM fact_capital_stock f
JOIN dim_geo g ON f.geo_id = g.geo_id
JOIN dim_unit u ON f.unit_id = u.unit_id
JOIN dim_nace n ON f.nace_id = n.nace_id
JOIN dim_asset a ON f.asset_id = a.asset_id
JOIN dim_na_item ni ON f.na_item_id = ni.na_item_id
WHERE f.year = 2020;
