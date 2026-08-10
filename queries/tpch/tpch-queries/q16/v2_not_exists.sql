-- TPC-H Q16: Parts/Supplier Relationship - variant: not_exists
-- Generated from tpch-dbgen by generate_tpch_query_set.py (validation params, PG fixes).
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
select
	p_brand, p_type, p_size, count(distinct ps_suppkey) as supplier_cnt
from
	partsupp, part
where
	p_partkey = ps_partkey
	and p_brand <> 'Brand#45'
	and p_type not like 'MEDIUM POLISHED%'
	and p_size in (49, 14, 23, 45, 19, 3, 36, 9)
	and not exists (
		select 1 from supplier
		where s_suppkey = ps_suppkey and s_comment like '%Customer%Complaints%'
	)
group by
	p_brand, p_type, p_size
order by
	supplier_cnt desc, p_brand, p_type, p_size;
