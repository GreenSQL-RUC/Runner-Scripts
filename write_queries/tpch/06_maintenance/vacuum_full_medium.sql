-- Maintenance: VACUUM, VACUUM FULL, ANALYZE
-- Operation: vacuum_full_medium
-- VACUUM FULL on the same bloated table: rewrites the whole heap to shrink it.
-- Isolated write: runs only on the scratch DB (tpch_write). Everything up to
-- @MEASURE is SETUP - it rebuilds a disposable w_* table from read-only
-- reference data and is NOT timed; only the statement after @MEASURE is measured.
DROP TABLE IF EXISTS w_lineitem;
CREATE TABLE w_lineitem AS SELECT * FROM lineitem LIMIT 100000;
UPDATE w_lineitem SET l_quantity = l_quantity + 1;
-- @MEASURE
VACUUM FULL w_lineitem;
