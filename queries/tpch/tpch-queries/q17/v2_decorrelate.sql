-- TPC-H Q17: Small-Quantity-Order Revenue - variant: decorrelate
-- Generated from tpch-dbgen by generate_tpch_query_set.py (validation params, PG fixes).
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
select
	sum(l_extendedprice) / 7.0 as avg_yearly
from
	lineitem, part,
	(select l_partkey as pk, 0.2 * avg(l_quantity) as thresh
	 from lineitem group by l_partkey) as avgq
where
	p_partkey = l_partkey
	and p_brand = 'Brand#23'
	and p_container = 'MED BOX'
	and avgq.pk = p_partkey
	and l_quantity < avgq.thresh;
