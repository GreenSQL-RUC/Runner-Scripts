-- 9.7 Pattern Matching
-- Operation: regexp_split_to_array
-- The like/regex pairs use equivalent patterns so LIKE, SIMILAR TO and POSIX
-- regex can be compared directly on identical work.
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT regexp_split_to_array(l_comment, ' ')
FROM lineitem;
