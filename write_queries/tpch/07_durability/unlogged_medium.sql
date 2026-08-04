-- Durability: synchronous_commit on/off, UNLOGGED
-- Operation: unlogged_medium
-- 100k INSERT into an UNLOGGED table: skips WAL entirely - compare
-- 01_insert/bulk_medium (logged).
-- Isolated write: runs only on the scratch DB (tpch_write). Everything up to
-- @MEASURE is SETUP - it rebuilds a disposable w_* table from read-only
-- reference data and is NOT timed; only the statement after @MEASURE is measured.
DROP TABLE IF EXISTS w_unlogged;
CREATE UNLOGGED TABLE w_unlogged (LIKE lineitem INCLUDING DEFAULTS);
-- @MEASURE
INSERT INTO w_unlogged SELECT * FROM lineitem LIMIT 100000;
