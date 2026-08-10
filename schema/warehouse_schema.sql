DROP TABLE IF EXISTS sales;
DROP TABLE IF EXISTS items;
DROP TABLE IF EXISTS suppliers;
DROP TABLE IF EXISTS staging_sales;

CREATE TABLE suppliers(
    supplier_id SERIAL PRIMARY KEY, 
    supplier_name VARCHAR(40) UNIQUE NOT NULL 
);

CREATE TABLE items(
    item_id SERIAL PRIMARY KEY, 
    item_code VARCHAR(10) NOT NULL,
    item_description VARCHAR(120), 
    item_type VARCHAR(20), 
    UNIQUE (item_code, item_description, item_type) 
);

CREATE TABLE sales(
    id SERIAL PRIMARY KEY, 
    sale_year SMALLINT NOT NULL, 
    sale_month SMALLINT NOT NULL, 
    supplier_id INTEGER REFERENCES suppliers(supplier_id), 
    item_id INTEGER REFERENCES items(item_id), 
    retail_sales NUMERIC(10,2), 
    retail_transfers NUMERIC(10,2),
    warehouse_sales NUMERIC(10,2)  
);

CREATE TABLE staging_sales(
    sale_year SMALLINT, sale_month SMALLINT, supplier VARCHAR(40),
    item_code VARCHAR(10), item_description VARCHAR(120), item_type VARCHAR(20),  
    retail_sales TEXT, retail_transfers TEXT, warehouse_sales TEXT
);


