-- Transactions: rollback (work-only), many small statements
-- Operation: rollback_medium
-- 100k INSERT then ROLLBACK: measures write WORK (WAL generation, tuple
-- building) WITHOUT the durable commit - the 'work mode' counterpart to a
-- committed bulk INSERT. The ROLLBACK also self-resets the table.
-- Isolated write: runs only on the scratch DB (tpch_write). Everything above
-- the marker line is SETUP - it rebuilds a disposable w_* table from read-only
-- reference data and is NOT timed. write_runner then quiesces the scratch tables,
-- drops caches and restarts the cluster, so only the statement below the marker
-- is measured, always from a cold start.
DROP TABLE IF EXISTS w_lineitem;
CREATE TABLE w_lineitem (LIKE lineitem INCLUDING DEFAULTS);
-- @MEASURE
BEGIN;
INSERT INTO w_lineitem SELECT * FROM lineitem LIMIT 100000;
ROLLBACK;
