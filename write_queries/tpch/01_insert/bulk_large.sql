-- INSERT: bulk load, single row, indexed target, upsert
-- Operation: bulk_large
-- Bulk INSERT ... SELECT of 1000000 rows into an empty heap (no indexes).
-- Isolated write: runs only on the scratch DB (tpch_write). Everything up to
-- @MEASURE is SETUP - it rebuilds a disposable w_* table from read-only
-- reference data and is NOT timed; only the statement after @MEASURE is measured.
DROP TABLE IF EXISTS w_lineitem;
CREATE TABLE w_lineitem (LIKE lineitem INCLUDING DEFAULTS);
-- @MEASURE
INSERT INTO w_lineitem SELECT * FROM lineitem LIMIT 1000000;
