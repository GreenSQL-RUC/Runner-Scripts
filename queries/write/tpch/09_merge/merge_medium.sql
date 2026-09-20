-- MERGE: matched-update / not-matched-insert
-- Operation: merge_medium
-- MERGE (PG15+): 100k source rows into a 50k target keyed on
-- (l_orderkey, l_linenumber) - half UPDATE (matched), half INSERT (not).
-- Isolated write: runs only on the scratch DB (tpch_write). Everything above
-- the marker line is SETUP - it rebuilds a disposable w_* table from read-only
-- reference data and is NOT timed. write_runner then quiesces the scratch tables,
-- drops caches and restarts the cluster, so only the statement below the marker
-- is measured, always from a cold start.
DROP TABLE IF EXISTS w_target;
CREATE TABLE w_target AS SELECT l_orderkey, l_linenumber, l_quantity FROM lineitem LIMIT 50000;
ALTER TABLE w_target ADD PRIMARY KEY (l_orderkey, l_linenumber);
DROP TABLE IF EXISTS w_source;
CREATE TABLE w_source AS SELECT l_orderkey, l_linenumber, l_quantity FROM lineitem LIMIT 100000;
-- @MEASURE
MERGE INTO w_target t USING w_source s
  ON t.l_orderkey = s.l_orderkey AND t.l_linenumber = s.l_linenumber
  WHEN MATCHED THEN UPDATE SET l_quantity = s.l_quantity
  WHEN NOT MATCHED THEN INSERT (l_orderkey, l_linenumber, l_quantity)
    VALUES (s.l_orderkey, s.l_linenumber, s.l_quantity);
