-- Join methods: same join, forced algorithm
-- large_* = sales JOIN items (319k x 41k)

SET enable_mergejoin = off;
SET enable_nestloop = off;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT 1 FROM sales s JOIN items i ON s.item_id = i.item_id;