-- INSERT: bulk load, single row, indexed target, upsert
-- Operation: single_row
-- One-row INSERT: the per-statement floor (parse/plan/commit dominate).
-- Isolated write: runs only on the scratch DB (tpch_write). Everything up to
-- @MEASURE is SETUP - it rebuilds a disposable w_* table from read-only
-- reference data and is NOT timed; only the statement after @MEASURE is measured.
DROP TABLE IF EXISTS w_lineitem;
CREATE TABLE w_lineitem (LIKE lineitem INCLUDING DEFAULTS);
-- @MEASURE
INSERT INTO w_lineitem SELECT * FROM lineitem LIMIT 1;
