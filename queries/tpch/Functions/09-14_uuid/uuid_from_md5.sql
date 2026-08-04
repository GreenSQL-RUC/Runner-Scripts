-- 9.14 UUID Functions
-- Operation: uuid_from_md5
-- Note: uuidv4()/uuidv7() are PostgreSQL 18 additions and do not exist on the
-- 16.14 server this was verified against; gen_random_uuid() is the v4 equivalent.
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT md5(l_comment)::uuid
FROM lineitem;
