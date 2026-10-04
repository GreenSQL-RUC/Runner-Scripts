-- compare probe: memory latency. Six parallel hash self-joins of posthistory
-- (~40 MB hash table each, far larger than the CPU cache; `+ 0` keeps the
-- planner off the primary-key index).
SELECT count(*), sum(s) FROM (
SELECT count(*) AS c, sum(a.postid::bigint + b.userid) AS s
  FROM posthistory a JOIN posthistory b ON b.id = a.id + 0
UNION ALL
SELECT count(*) AS c, sum(a.postid::bigint + b.userid) AS s
  FROM posthistory a JOIN posthistory b ON b.id = a.id + 0
UNION ALL
SELECT count(*) AS c, sum(a.postid::bigint + b.userid) AS s
  FROM posthistory a JOIN posthistory b ON b.id = a.id + 0
UNION ALL
SELECT count(*) AS c, sum(a.postid::bigint + b.userid) AS s
  FROM posthistory a JOIN posthistory b ON b.id = a.id + 0
UNION ALL
SELECT count(*) AS c, sum(a.postid::bigint + b.userid) AS s
  FROM posthistory a JOIN posthistory b ON b.id = a.id + 0
UNION ALL
SELECT count(*) AS c, sum(a.postid::bigint + b.userid) AS s
  FROM posthistory a JOIN posthistory b ON b.id = a.id + 0
) t;
