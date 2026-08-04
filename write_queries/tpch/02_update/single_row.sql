-- UPDATE: bulk, indexed-column churn vs HOT, single row
-- Operation: single_row
-- UPDATE one row located by an indexed key.
-- Isolated write: runs only on the scratch DB (tpch_write). Everything up to
-- @MEASURE is SETUP - it rebuilds a disposable w_* table from read-only
-- reference data and is NOT timed; only the statement after @MEASURE is measured.
DROP TABLE IF EXISTS w_lineitem;
CREATE TABLE w_lineitem AS SELECT * FROM lineitem LIMIT 100000;
CREATE INDEX w_lineitem_key ON w_lineitem(l_orderkey);
-- @MEASURE
UPDATE w_lineitem SET l_quantity = l_quantity + 1 WHERE l_orderkey = 1;
