-- Derived tables
-- dimensions are turned into tables before being joined

EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
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

JOIN (
    SELECT geo_id, geo_code
    FROM dim_geo
) AS g
    ON g.geo_id = f.geo_id

JOIN (
    SELECT unit_id, unit_code
    FROM dim_unit
) AS u
    ON u.unit_id = f.unit_id

JOIN (
    SELECT nace_id, nace_code
    FROM dim_nace
) AS n
    ON n.nace_id = f.nace_id

JOIN (
    SELECT asset_id, asset_code
    FROM dim_asset
) AS a
    ON a.asset_id = f.asset_id

JOIN (
    SELECT na_item_id, na_item_code
    FROM dim_na_item
) AS ni
    ON ni.na_item_id = f.na_item_id

WHERE f.value IS NOT NULL

ORDER BY
    f.year,
    g.geo_code,
    u.unit_code,
    n.nace_code,
    a.asset_code,
    ni.na_item_code;