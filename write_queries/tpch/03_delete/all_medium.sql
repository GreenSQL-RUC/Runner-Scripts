-- DELETE: bulk, delete-all vs TRUNCATE, single row
-- Operation: all_medium
-- DELETE every row (100k): full-table delete, marks all tuples dead
-- (compare truncate_medium).
-- Isolated write: runs only on the scratch DB (tpch_write). Everything up to
-- @MEASURE is SETUP - it rebuilds a disposable w_* table from read-only
-- reference data and is NOT timed; only the statement after @MEASURE is measured.
DROP TABLE IF EXISTS w_lineitem;
CREATE TABLE w_lineitem AS SELECT * FROM lineitem LIMIT 100000;
-- @MEASURE
DELETE FROM w_lineitem;
