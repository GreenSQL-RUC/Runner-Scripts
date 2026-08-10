-- TPC-H Q12: Shipping Modes and Order Priority - variant: filter
-- Generated from tpch-dbgen by generate_tpch_query_set.py (validation params, PG fixes).
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
select
	l_shipmode,
	count(*) filter (where o_orderpriority in ('1-URGENT', '2-HIGH')) as high_line_count,
	count(*) filter (where o_orderpriority not in ('1-URGENT', '2-HIGH')) as low_line_count
from
	orders, lineitem
where
	o_orderkey = l_orderkey
	and l_shipmode in ('MAIL', 'SHIP')
	and l_commitdate < l_receiptdate
	and l_shipdate < l_commitdate
	and l_receiptdate >= date '1994-01-01'
	and l_receiptdate < date '1994-01-01' + interval '1' year
group by
	l_shipmode
order by
	l_shipmode;
