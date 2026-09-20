-- DELETE: bulk, delete-all vs TRUNCATE, single row
-- Operation: truncate_medium
-- TRUNCATE the same 100k table: a metadata/file operation, not a per-row
-- delete - the cheap contrast with all_medium.
-- Isolated write: runs only on the scratch DB (tpch_write). Everything above
-- the marker line is SETUP - it rebuilds a disposable w_* table from read-only
-- reference data and is NOT timed. write_runner then quiesces the scratch tables,
-- drops caches and restarts the cluster, so only the statement below the marker
-- is measured, always from a cold start.
DROP TABLE IF EXISTS w_lineitem;
CREATE TABLE w_lineitem AS SELECT * FROM lineitem LIMIT 100000;
-- @MEASURE
TRUNCATE w_lineitem;
