-- COPY: bulk load at three scales
-- Operation: copy_small
-- Bulk load of 1000 rows via server-side COPY FROM (the fast load path).
-- SETUP writes the data file with COPY ... TO; only COPY FROM is timed.
-- Isolated write: runs only on the scratch DB (tpch_write). Everything above
-- the marker line is SETUP - it rebuilds a disposable w_* table from read-only
-- reference data and is NOT timed. write_runner then quiesces the scratch tables,
-- drops caches and restarts the cluster, so only the statement below the marker
-- is measured, always from a cold start.
DROP TABLE IF EXISTS w_lineitem;
CREATE TABLE w_lineitem (LIKE lineitem INCLUDING DEFAULTS);
COPY (SELECT * FROM lineitem LIMIT 1000) TO '/tmp/w_copy_small.csv' WITH (FORMAT csv);
-- @MEASURE
COPY w_lineitem FROM '/tmp/w_copy_small.csv' WITH (FORMAT csv);
