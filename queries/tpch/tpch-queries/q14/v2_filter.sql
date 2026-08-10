-- TPC-H Q14: Promotion Effect - variant: filter
-- Generated from tpch-dbgen by generate_tpch_query_set.py (validation params, PG fixes).
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
select
	100.00 * sum(l_extendedprice * (1 - l_discount)) filter (where p_type like 'PROMO%')
		/ sum(l_extendedprice * (1 - l_discount)) as promo_revenue
from
	lineitem, part
where
	l_partkey = p_partkey
	and l_shipdate >= date '1995-09-01'
	and l_shipdate < date '1995-09-01' + interval '1' month;
