SET enable_seqscan = on;
SET enable_indexscan = off;
SET enable_bitmapscan = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT value FROM fact_capital_stock WHERE year BETWEEN 2000 and 2010;