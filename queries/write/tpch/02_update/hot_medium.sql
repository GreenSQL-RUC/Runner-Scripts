-- UPDATE: bulk, indexed-column churn vs HOT, single row
-- Operation: hot_medium
-- UPDATE a NON-indexed column on the same indexed table: a Heap-Only Tuple
-- update with no index churn - the pair with indexed_col_medium.
-- Isolated write: runs only on the scratch DB (tpch_write). Everything above
-- the marker line is SETUP - it rebuilds a disposable w_* table from read-only
-- reference data and is NOT timed. write_runner then quiesces the scratch tables,
-- drops caches and restarts the cluster, so only the statement below the marker
-- is measured, always from a cold start.
DROP TABLE IF EXISTS w_lineitem;
CREATE TABLE w_lineitem AS SELECT * FROM lineitem LIMIT 100000;
CREATE INDEX w_lineitem_key ON w_lineitem(l_orderkey);
-- @MEASURE
UPDATE w_lineitem SET l_quantity = l_quantity + 1;
