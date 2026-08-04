-- Durability: synchronous_commit on/off, UNLOGGED
-- Operation: sync_commit_off_medium
-- Same 100k INSERT with synchronous_commit=off: no per-commit fsync wait -
-- the durability-cost pair with sync_commit_on_medium.
-- Isolated write: runs only on the scratch DB (tpch_write). Everything up to
-- @MEASURE is SETUP - it rebuilds a disposable w_* table from read-only
-- reference data and is NOT timed; only the statement after @MEASURE is measured.
DROP TABLE IF EXISTS w_lineitem;
CREATE TABLE w_lineitem (LIKE lineitem INCLUDING DEFAULTS);
-- @MEASURE
SET synchronous_commit = off;
INSERT INTO w_lineitem SELECT * FROM lineitem LIMIT 100000;
