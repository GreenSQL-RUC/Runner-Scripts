-- Maintenance: VACUUM, VACUUM FULL, ANALYZE
-- Operation: analyze_medium
-- ANALYZE: resample planner statistics over 100k rows.
-- Isolated write: runs only on the scratch DB (tpch_write). Everything up to
-- @MEASURE is SETUP - it rebuilds a disposable w_* table from read-only
-- reference data and is NOT timed; only the statement after @MEASURE is measured.
DROP TABLE IF EXISTS w_lineitem;
CREATE TABLE w_lineitem AS SELECT * FROM lineitem LIMIT 100000;
-- @MEASURE
ANALYZE w_lineitem;
