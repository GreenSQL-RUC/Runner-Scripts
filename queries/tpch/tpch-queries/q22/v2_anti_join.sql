-- TPC-H Q22: Global Sales Opportunity - variant: anti_join
-- Generated from tpch-dbgen by generate_tpch_query_set.py (validation params, PG fixes).
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
select
	cntrycode, count(*) as numcust, sum(c_acctbal) as totacctbal
from (
	select substring(c_phone from 1 for 2) as cntrycode, c_acctbal
	from customer left join orders on o_custkey = c_custkey
	where substring(c_phone from 1 for 2) in ('13', '31', '23', '29', '30', '18', '17')
		and c_acctbal > (
			select avg(c_acctbal) from customer
			where c_acctbal > 0.00
			and substring(c_phone from 1 for 2) in ('13', '31', '23', '29', '30', '18', '17')
		)
		and o_orderkey is null
) as custsale
group by
	cntrycode
order by
	cntrycode;
