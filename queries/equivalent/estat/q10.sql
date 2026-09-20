-- Nested query 

EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT
    x.year,
    x.geo_code,
    x.unit_code,
    x.nace_code,
    x.asset_code,
    x.na_item_code,
    x.value,
    x.flag
FROM (
    SELECT
        f.year,
        (
            SELECT geo_code
            FROM dim_geo
            WHERE geo_id = f.geo_id
        ) AS geo_code,
        (
            SELECT unit_code
            FROM dim_unit
            WHERE unit_id = f.unit_id
        ) AS unit_code,
        (
            SELECT nace_code
            FROM dim_nace
            WHERE nace_id = f.nace_id
        ) AS nace_code,
        (
            SELECT asset_code
            FROM dim_asset
            WHERE asset_id = f.asset_id
        ) AS asset_code,
        (
            SELECT na_item_code
            FROM dim_na_item
            WHERE na_item_id = f.na_item_id
        ) AS na_item_code,
        f.value,
        f.flag
    FROM fact_capital_stock f
    WHERE f.value IS NOT NULL
) AS x
ORDER BY
    x.year,
    x.geo_code,
    x.unit_code,
    x.nace_code,
    x.asset_code,
    x.na_item_code;