-- DDL: index build, REINDEX, CLUSTER
-- Operation: reindex_medium
-- REINDEX an existing btree (100k): rebuild it from scratch.
-- Isolated write: runs only on the scratch DB (tpch_write). Everything up to
-- @MEASURE is SETUP - it rebuilds a disposable w_* table from read-only
-- reference data and is NOT timed; only the statement after @MEASURE is measured.
DROP TABLE IF EXISTS w_lineitem;
CREATE TABLE w_lineitem AS SELECT * FROM lineitem LIMIT 100000;
CREATE INDEX w_lineitem_key ON w_lineitem(l_orderkey);
-- @MEASURE
REINDEX INDEX w_lineitem_key;
