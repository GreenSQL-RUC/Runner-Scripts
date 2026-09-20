-- Same logical resutls, but dimensions and facts are expressed as CTEs

EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
WITH facts AS (
    SELECT
        year,
        geo_id,
        unit_id,
        nace_id,
        asset_id,
        na_item_id,
        value,
        flag
    FROM fact_capital_stock
    WHERE value IS NOT NULL
),
geos AS (
    SELECT geo_id, geo_code
    FROM dim_geo
),
units AS (
    SELECT unit_id, unit_code
    FROM dim_unit
),
naces AS (
    SELECT nace_id, nace_code
    FROM dim_nace
),
assets AS (
    SELECT asset_id, asset_code
    FROM dim_asset
),
items AS (
    SELECT na_item_id, na_item_code
    FROM dim_na_item
)
SELECT
    f.year,
    g.geo_code,
    u.unit_code,
    n.nace_code,
    a.asset_code,
    ni.na_item_code,
    f.value,
    f.flag
FROM facts AS f
JOIN geos AS g ON g.geo_id = f.geo_id
JOIN units AS u ON u.unit_id = f.unit_id
JOIN naces AS n ON n.nace_id = f.nace_id
JOIN assets AS a ON a.asset_id = f.asset_id
JOIN items AS ni ON ni.na_item_id = f.na_item_id
ORDER BY
    f.year,
    g.geo_code,
    u.unit_code,
    n.nace_code,
    a.asset_code,
    ni.na_item_code;