EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)

WITH order_revenue AS (
    SELECT
        l.l_orderkey,
        SUM(l.l_extendedprice * (1 - l.l_discount)) AS revenue
    FROM lineitem l
    GROUP BY l.l_orderkey
)
SELECT
    r.r_name AS region,
    n.n_name AS nation,
    SUM(orv.revenue) AS total_revenue,
    COUNT(*) AS order_count
FROM order_revenue orv
JOIN orders o
    ON o.o_orderkey = orv.l_orderkey
JOIN customer c
    ON c.c_custkey = o.o_custkey
JOIN nation n
    ON n.n_nationkey = c.c_nationkey
JOIN region r
    ON r.r_regionkey = n.n_regionkey
WHERE o.o_orderdate >= DATE '1995-01-01'
  AND o.o_orderdate <  DATE '1996-01-01'
GROUP BY
    r.r_name,
    n.n_name
ORDER BY
    r.r_name,
    n.n_name;