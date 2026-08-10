-- TPC-H Q4: Order Priority Checking - variant: in
-- Generated from tpch-dbgen by generate_tpch_query_set.py (validation params, PG fixes).
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
select
	o_orderpriority, count(*) as order_count
from
	orders
where
	o_orderdate >= date '1993-07-01'
	and o_orderdate < date '1993-07-01' + interval '3' month
	and o_orderkey in (
		select l_orderkey from lineitem where l_commitdate < l_receiptdate
	)
group by
	o_orderpriority
order by
	o_orderpriority;
