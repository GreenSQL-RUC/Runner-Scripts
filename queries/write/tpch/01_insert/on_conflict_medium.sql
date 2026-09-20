-- INSERT: bulk load, single row, indexed target, upsert
-- Operation: on_conflict_medium
-- Upsert: INSERT ... ON CONFLICT DO UPDATE of 100k rows into a 50k table so
-- half collide (UPDATE path) and half are new (INSERT path).
-- Isolated write: runs only on the scratch DB (tpch_write). Everything above
-- the marker line is SETUP - it rebuilds a disposable w_* table from read-only
-- reference data and is NOT timed. write_runner then quiesces the scratch tables,
-- drops caches and restarts the cluster, so only the statement below the marker
-- is measured, always from a cold start.
DROP TABLE IF EXISTS w_upsert;
CREATE TABLE w_upsert AS SELECT * FROM lineitem LIMIT 50000;
ALTER TABLE w_upsert ADD PRIMARY KEY (l_orderkey, l_linenumber);
-- @MEASURE
INSERT INTO w_upsert SELECT * FROM lineitem LIMIT 100000
ON CONFLICT (l_orderkey, l_linenumber) DO UPDATE SET l_quantity = EXCLUDED.l_quantity;
