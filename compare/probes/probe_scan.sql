-- compare probe: memory bandwidth. posthistory (~490 MB, held in shared_buffers
-- after the warm-ups) scanned 40 times under a Parallel Append (4 workers).
SELECT count(*), sum(s) FROM (
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
UNION ALL
SELECT count(*) AS c, sum(postid::bigint) AS s FROM posthistory
) t;
