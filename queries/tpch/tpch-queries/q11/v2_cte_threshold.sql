-- TPC-H Q11: Important Stock Identification - variant: cte_threshold
-- Generated from tpch-dbgen by generate_tpch_query_set.py (validation params, PG fixes).
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
with total (v) as (
	select sum(ps_supplycost * ps_availqty) * 0.0001
	from partsupp, supplier, nation
	where ps_suppkey = s_suppkey and s_nationkey = n_nationkey and n_name = 'GERMANY'
)
select
	ps_partkey, sum(ps_supplycost * ps_availqty) as value
from
	partsupp, supplier, nation
where
	ps_suppkey = s_suppkey and s_nationkey = n_nationkey and n_name = 'GERMANY'
group by
	ps_partkey
having
	sum(ps_supplycost * ps_availqty) > (select v from total)
order by
	value desc;
