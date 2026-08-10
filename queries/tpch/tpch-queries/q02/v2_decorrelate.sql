-- TPC-H Q2: Minimum Cost Supplier - variant: decorrelate
-- Generated from tpch-dbgen by generate_tpch_query_set.py (validation params, PG fixes).
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
with mincost (mpartkey, mn) as (
	select ps_partkey, min(ps_supplycost)
	from partsupp, supplier, nation, region
	where s_suppkey = ps_suppkey
		and s_nationkey = n_nationkey
		and n_regionkey = r_regionkey
		and r_name = 'EUROPE'
	group by ps_partkey
)
select
	s_acctbal, s_name, n_name, p_partkey, p_mfgr, s_address, s_phone, s_comment
from
	part, supplier, partsupp, nation, region, mincost
where
	p_partkey = ps_partkey
	and s_suppkey = ps_suppkey
	and p_size = 15
	and p_type like '%BRASS'
	and s_nationkey = n_nationkey
	and n_regionkey = r_regionkey
	and r_name = 'EUROPE'
	and mincost.mpartkey = p_partkey
	and ps_supplycost = mincost.mn
order by
	s_acctbal desc, n_name, s_name, p_partkey
limit 100;
