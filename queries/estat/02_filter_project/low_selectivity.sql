-- flag IS NULL likely matches most rows (only footnoted values have flags)
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT value FROM fact_capital_stock WHERE flag IS NULL;