-- Transactions: rollback (work-only), many small statements
-- Operation: many_statements
-- 10,000 one-row INSERTs in a single transaction (a procedural loop):
-- isolates per-statement executor overhead against one bulk INSERT.
-- Isolated write: runs only on the scratch DB (tpch_write). Everything above
-- the marker line is SETUP - it rebuilds a disposable w_* table from read-only
-- reference data and is NOT timed. write_runner then quiesces the scratch tables,
-- drops caches and restarts the cluster, so only the statement below the marker
-- is measured, always from a cold start.
DROP TABLE IF EXISTS w_lineitem;
CREATE TABLE w_lineitem (LIKE lineitem INCLUDING DEFAULTS);
-- @MEASURE
DO $$ BEGIN
  FOR i IN 1..10000 LOOP
    INSERT INTO w_lineitem SELECT * FROM lineitem LIMIT 1;
  END LOOP;
END $$;
