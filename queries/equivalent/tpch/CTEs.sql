EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)

WITH filtered_orders AS (
    SELECT
        o_orderkey,
        o_custkey
    FROM orders
    WHERE o_orderdate >= DATE '1995-01-01'
      AND o_orderdate <  DATE '1996-01-01'
),
order_revenue AS (
    SELECT
        fo.o_orderkey,
        fo.o_custkey,
        SUM(l.l_extendedprice * (1 - l.l_discount)) AS revenue
    FROM filtered_orders fo
    JOIN lineitem l
        ON l.l_orderkey = fo.o_orderkey
    GROUP BY
        fo.o_orderkey,
        fo.o_custkey
)
SELECT
    r.r_name AS region,
    n.n_name AS nation,
    SUM(orv.revenue) AS total_revenue,
    COUNT(*) AS order_count
FROM order_revenue orv
JOIN customer c
    ON c.c_custkey = orv.o_custkey
JOIN nation n
    ON n.n_nationkey = c.c_nationkey
JOIN region r
    ON r.r_regionkey = n.n_regionkey
GROUP BY
    r.r_name,
    n.n_name
ORDER BY
    r.r_name,
    n.n_name;