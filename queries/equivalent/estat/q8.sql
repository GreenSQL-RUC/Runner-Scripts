-- Adding window function 
-- window function isnt necessary only the joins are 

EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
WITH joined AS (
    SELECT
        f.year,
        g.geo_code,
        u.unit_code,
        n.nace_code,
        a.asset_code,
        ni.na_item_code,
        f.value,
        f.flag
    FROM fact_capital_stock AS f
    JOIN dim_geo AS g ON g.geo_id = f.geo_id
    JOIN dim_unit AS u ON u.unit_id = f.unit_id
    JOIN dim_nace AS n ON n.nace_id = f.nace_id
    JOIN dim_asset AS a ON a.asset_id = f.asset_id
    JOIN dim_na_item AS ni ON ni.na_item_id = f.na_item_id
    WHERE f.value IS NOT NULL
),
numbered AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            ORDER BY
                year,
                geo_code,
                unit_code,
                nace_code,
                asset_code,
                na_item_code
        ) AS row_number
    FROM joined
)
SELECT
    year,
    geo_code,
    unit_code,
    nace_code,
    asset_code,
    na_item_code,
    value,
    flag
FROM numbered
ORDER BY row_number;