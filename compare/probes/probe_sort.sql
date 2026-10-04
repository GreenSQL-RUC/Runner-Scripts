-- compare probe: in-memory sort. One process quicksorts all of votes (~53 MB,
-- fits work_mem = 64 MB, so no temp files) under a window function.
SELECT sum(rn) FROM (SELECT row_number() OVER (ORDER BY userid, creationdate, id) AS rn FROM votes) s;
