EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)

SELECT
    x.r_name AS region,
    x.n_name AS nation,
    SUM(x.revenue) AS total_revenue,
    COUNT(*) AS order_count
FROM (
    SELECT
        r.r_name,
        n.n_name,
        o.o_orderkey,
        SUM(l.l_extendedprice * (1 - l.l_discount)) AS revenue
    FROM region r
    JOIN nation n
        ON n.n_regionkey = r.r_regionkey
    JOIN customer c
        ON c.c_nationkey = n.n_nationkey
    JOIN orders o
        ON o.o_custkey = c.c_custkey
    JOIN lineitem l
        ON l.l_orderkey = o.o_orderkey
    WHERE o.o_orderdate >= DATE '1995-01-01'
      AND o.o_orderdate <  DATE '1996-01-01'
    GROUP BY
        r.r_name,
        n.n_name,
        o.o_orderkey
) x
GROUP BY
    x.r_name,
    x.n_name
ORDER BY
    x.r_name,
    x.n_name;