-- UPDATE: bulk, indexed-column churn vs HOT, single row
-- Operation: all_medium
-- UPDATE every one of 100000 rows (each becomes a new tuple version).
-- Isolated write: runs only on the scratch DB (tpch_write). Everything up to
-- @MEASURE is SETUP - it rebuilds a disposable w_* table from read-only
-- reference data and is NOT timed; only the statement after @MEASURE is measured.
DROP TABLE IF EXISTS w_lineitem;
CREATE TABLE w_lineitem AS SELECT * FROM lineitem LIMIT 100000;
-- @MEASURE
UPDATE w_lineitem SET l_quantity = l_quantity + 1;
