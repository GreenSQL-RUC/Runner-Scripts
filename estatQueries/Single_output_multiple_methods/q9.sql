-- UNION ALL by year
-- shows that th same result can be assembled from multiple queries

EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT
    year,
    geo_code,
    unit_code,
    nace_code,
    asset_code,
    na_item_code,
    value,
    flag
FROM (
    SELECT
        f.year,
        g.geo_code,
        u.unit_code,
        n.nace_code,
        a.asset_code,
        ni.na_item_code,
        f.value,
        f.flag
    FROM fact_capital_stock f
    JOIN dim_geo g ON g.geo_id = f.geo_id
    JOIN dim_unit u ON u.unit_id = f.unit_id
    JOIN dim_nace n ON n.nace_id = f.nace_id
    JOIN dim_asset a ON a.asset_id = f.asset_id
    JOIN dim_na_item ni ON ni.na_item_id = f.na_item_id
    WHERE f.value IS NOT NULL
) AS x
ORDER BY
    year,
    geo_code,
    unit_code,
    nace_code,
    asset_code,
    na_item_code;