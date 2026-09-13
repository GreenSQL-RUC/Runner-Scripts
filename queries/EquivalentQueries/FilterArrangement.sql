EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)

SELECT
    r.r_name AS region,
    n.n_name AS nation,
    SUM(x.revenue) AS total_revenue,
    COUNT(*) AS order_count
FROM region r
JOIN nation n
    ON n.n_regionkey = r.r_regionkey
JOIN customer c
    ON c.c_nationkey = n.n_nationkey
JOIN orders o
    ON o.o_custkey = c.c_custkey
CROSS JOIN LATERAL (
    SELECT
        SUM(l.l_extendedprice * (1 - l.l_discount)) AS revenue
    FROM lineitem l
    WHERE l.l_orderkey = o.o_orderkey
) x
WHERE o.o_orderdate >= DATE '1995-01-01'
  AND o.o_orderdate <  DATE '1996-01-01'
GROUP BY
    r.r_name,
    n.n_name
ORDER BY
    r.r_name,
    n.n_name;