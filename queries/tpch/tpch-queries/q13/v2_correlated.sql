-- TPC-H Q13: Customer Distribution - variant: correlated
-- Generated from tpch-dbgen by generate_tpch_query_set.py (validation params, PG fixes).
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
select
	c_count, count(*) as custdist
from (
	select c_custkey,
		(select count(*) from orders
		 where o_custkey = c_custkey and o_comment not like '%special%requests%') as c_count
	from customer
) as c_orders
group by
	c_count
order by
	custdist desc, c_count desc;
