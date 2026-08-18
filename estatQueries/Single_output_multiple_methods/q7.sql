-- Lateral
-- using Postgresql's LATERAL feature

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

CROSS JOIN LATERAL (
    SELECT geo_code
    FROM dim_geo
    WHERE geo_id = f.geo_id
) AS g

CROSS JOIN LATERAL (
    SELECT unit_code
    FROM dim_unit
    WHERE unit_id = f.unit_id
) AS u

CROSS JOIN LATERAL (
    SELECT nace_code
    FROM dim_nace
    WHERE nace_id = f.nace_id
) AS n

CROSS JOIN LATERAL (
    SELECT asset_code
    FROM dim_asset
    WHERE asset_id = f.asset_id
) AS a

CROSS JOIN LATERAL (
    SELECT na_item_code
    FROM dim_na_item
    WHERE na_item_id = f.na_item_id
) AS ni

WHERE f.value IS NOT NULL

ORDER BY
    f.year,
    g.geo_code,
    u.unit_code,
    n.nace_code,
    a.asset_code,
    ni.na_item_code;