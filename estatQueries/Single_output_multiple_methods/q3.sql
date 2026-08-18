-- Correlated scalar subqueries
--insttead of joining the dimensions, each code is looked up with a 
-- correlated subquery.

EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT
    f.year,

    (
        SELECT g.geo_code
        FROM dim_geo AS g
        WHERE g.geo_id = f.geo_id
    ) AS geo_code,

    (
        SELECT u.unit_code
        FROM dim_unit AS u
        WHERE u.unit_id = f.unit_id
    ) AS unit_code,

    (
        SELECT n.nace_code
        FROM dim_nace AS n
        WHERE n.nace_id = f.nace_id
    ) AS nace_code,

    (
        SELECT a.asset_code
        FROM dim_asset AS a
        WHERE a.asset_id = f.asset_id
    ) AS asset_code,

    (
        SELECT ni.na_item_code
        FROM dim_na_item AS ni
        WHERE ni.na_item_id = f.na_item_id
    ) AS na_item_code,

    f.value,
    f.flag

FROM fact_capital_stock AS f
WHERE f.value IS NOT NULL
ORDER BY
    f.year,
    geo_code,
    unit_code,
    nace_code,
    asset_code,
    na_item_code;