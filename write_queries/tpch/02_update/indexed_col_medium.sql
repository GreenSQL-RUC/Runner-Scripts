-- UPDATE: bulk, indexed-column churn vs HOT, single row
-- Operation: indexed_col_medium
-- UPDATE an INDEXED column (100k rows): each row's index entry must move,
-- so this pays heap + index churn.
-- Isolated write: runs only on the scratch DB (tpch_write). Everything up to
-- @MEASURE is SETUP - it rebuilds a disposable w_* table from read-only
-- reference data and is NOT timed; only the statement after @MEASURE is measured.
DROP TABLE IF EXISTS w_lineitem;
CREATE TABLE w_lineitem AS SELECT * FROM lineitem LIMIT 100000;
CREATE INDEX w_lineitem_key ON w_lineitem(l_orderkey);
-- @MEASURE
UPDATE w_lineitem SET l_orderkey = l_orderkey + 1;
