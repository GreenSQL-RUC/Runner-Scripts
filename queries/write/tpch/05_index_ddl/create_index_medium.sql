-- DDL: index build, REINDEX, CLUSTER
-- Operation: create_index_medium
-- Build a btree index over 100000 rows (CREATE INDEX sort + write).
-- Isolated write: runs only on the scratch DB (tpch_write). Everything above
-- the marker line is SETUP - it rebuilds a disposable w_* table from read-only
-- reference data and is NOT timed. write_runner then quiesces the scratch tables,
-- drops caches and restarts the cluster, so only the statement below the marker
-- is measured, always from a cold start.
DROP TABLE IF EXISTS w_lineitem;
CREATE TABLE w_lineitem AS SELECT * FROM lineitem LIMIT 100000;
-- @MEASURE
CREATE INDEX w_lineitem_bx ON w_lineitem(l_partkey);
