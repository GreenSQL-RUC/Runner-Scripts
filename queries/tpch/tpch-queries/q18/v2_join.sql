-- TPC-H Q18: Large Volume Customer - variant: join
-- Generated from tpch-dbgen by generate_tpch_query_set.py (validation params, PG fixes).
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
select
	c_name, c_custkey, o_orderkey, o_orderdate, o_totalprice, sum(l_quantity)
from
	customer, orders, lineitem,
	(select l_orderkey from lineitem group by l_orderkey
	 having sum(l_quantity) > 300) as big
where
	big.l_orderkey = o_orderkey
	and c_custkey = o_custkey
	and o_orderkey = lineitem.l_orderkey
group by
	c_name, c_custkey, o_orderkey, o_orderdate, o_totalprice
order by
	o_totalprice desc, o_orderdate
limit 100;
