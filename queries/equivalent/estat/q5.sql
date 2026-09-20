-- IN subqueries
-- another formulation 

EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
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
FROM fact_capital_stock AS f
WHERE f.value IS NOT NULL
  AND f.geo_id IN (
      SELECT geo_id FROM dim_geo
  )
  AND f.unit_id IN (
      SELECT unit_id FROM dim_unit
  )
  AND f.nace_id IN (
      SELECT nace_id FROM dim_nace
  )
  AND f.asset_id IN (
      SELECT asset_id FROM dim_asset
  )
  AND f.na_item_id IN (
      SELECT na_item_id FROM dim_na_item
  )
ORDER BY
    f.year,
    geo_code,
    unit_code,
    nace_code,
    asset_code,
    na_item_code;