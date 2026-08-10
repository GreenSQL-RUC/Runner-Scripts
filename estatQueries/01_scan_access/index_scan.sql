-- Requires: CREATE INDEX idx_fact_year ON fact_capital_stock(year);
SET enable_seqscan = off;
SET enable_indexscan = on;
SET enable_bitmapscan = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT value FROM fact_capital_stock WHERE year BETWEEN 2000 and 2010;