DROP TABLE IF EXISTS fact_capital_stock;
DROP TABLE IF EXISTS dim_geo;
DROP TABLE IF EXISTS dim_unit;
DROP TABLE IF EXISTS dim_nace;
DROP TABLE IF EXISTS dim_asset;
DROP TABLE IF EXISTS dim_na_item;
DROP TABLE IF EXISTS staging_capital_stock;

CREATE TABLE dim_geo (
    geo_id SERIAL PRIMARY KEY,
    geo_code VARCHAR(10) UNIQUE NOT NULL
);

CREATE TABLE dim_unit (
    unit_id SERIAL PRIMARY KEY,
    unit_code VARCHAR(30) UNIQUE NOT NULL
);

CREATE TABLE dim_nace (
    nace_id SERIAL PRIMARY KEY,
    nace_code VARCHAR(30) UNIQUE NOT NULL
);

CREATE TABLE dim_asset (
    asset_id SERIAL PRIMARY KEY,
    asset_code VARCHAR(30) UNIQUE NOT NULL
);

CREATE TABLE dim_na_item (
    na_item_id SERIAL PRIMARY KEY,
    na_item_code VARCHAR(30) UNIQUE NOT NULL
);

CREATE TABLE fact_capital_stock (
    fact_id SERIAL PRIMARY KEY,
    year SMALLINT NOT NULL,
    geo_id INTEGER REFERENCES dim_geo(geo_id),
    unit_id INTEGER REFERENCES dim_unit(unit_id),
    nace_id INTEGER REFERENCES dim_nace(nace_id),
    asset_id INTEGER REFERENCES dim_asset(asset_id),
    na_item_id INTEGER REFERENCES dim_na_item(na_item_id),
    value NUMERIC,
    flag VARCHAR(5),

    UNIQUE(
        year,
        geo_id,
        unit_id,
        nace_id,
        asset_id,
        na_item_id
    )
);