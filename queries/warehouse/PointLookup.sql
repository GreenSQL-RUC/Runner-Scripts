-- minimal work: a good cold/warm cache baseline comparison
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT * FROM sales WHERE id = 12345;
