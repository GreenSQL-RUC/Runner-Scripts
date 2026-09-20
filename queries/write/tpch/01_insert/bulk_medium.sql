-- INSERT: bulk load, single row, indexed target, upsert
-- Operation: bulk_medium
-- Bulk INSERT ... SELECT of 100000 rows into an empty heap (no indexes).
-- Isolated write: runs only on the scratch DB (tpch_write). Everything above
-- the marker line is SETUP - it rebuilds a disposable w_* table from read-only
-- reference data and is NOT timed. write_runner then quiesces the scratch tables,
-- drops caches and restarts the cluster, so only the statement below the marker
-- is measured, always from a cold start.
DROP TABLE IF EXISTS w_lineitem;
CREATE TABLE w_lineitem (LIKE lineitem INCLUDING DEFAULTS);
-- @MEASURE
INSERT INTO w_lineitem SELECT * FROM lineitem LIMIT 100000;
