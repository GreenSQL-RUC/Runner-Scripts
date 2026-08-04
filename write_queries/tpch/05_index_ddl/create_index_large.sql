-- DDL: index build, REINDEX, CLUSTER
-- Operation: create_index_large
-- Build a btree index over 1000000 rows (CREATE INDEX sort + write).
-- Isolated write: runs only on the scratch DB (tpch_write). Everything up to
-- @MEASURE is SETUP - it rebuilds a disposable w_* table from read-only
-- reference data and is NOT timed; only the statement after @MEASURE is measured.
DROP TABLE IF EXISTS w_lineitem;
CREATE TABLE w_lineitem AS SELECT * FROM lineitem LIMIT 1000000;
-- @MEASURE
CREATE INDEX w_lineitem_bx ON w_lineitem(l_partkey);
