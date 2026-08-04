-- DELETE: bulk, delete-all vs TRUNCATE, single row
-- Operation: bulk_small
-- DELETE ~half of a 1000-row table (l_quantity <= 25).
-- Isolated write: runs only on the scratch DB (tpch_write). Everything up to
-- @MEASURE is SETUP - it rebuilds a disposable w_* table from read-only
-- reference data and is NOT timed; only the statement after @MEASURE is measured.
DROP TABLE IF EXISTS w_lineitem;
CREATE TABLE w_lineitem AS SELECT * FROM lineitem LIMIT 1000;
-- @MEASURE
DELETE FROM w_lineitem WHERE l_quantity <= 25;
