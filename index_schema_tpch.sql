-- index_schema_tpch.sql
-- Extensive index suite for the indexed-test databases (tpch_idx / tpch2_idx /
-- tpch5_idx) - architecture B of INDEXED_TEST_PLAN.md.
--
-- Every index is prefixed  ixtest_  so teardown and default-state verification
-- can target them precisely and NEVER touch the three default indexes the base
-- build creates (idx_lineitem_order, idx_orders_cust, idx_customer_nation).
--
-- Applied by build_indexed.sh to a fresh TEMPLATE clone of a base DB; the script
-- runs ANALYZE afterward. Idempotent (IF NOT EXISTS), so it is safe to re-apply.
-- The base build indexes only l_orderkey, o_custkey and c_nationkey, so most
-- primary/foreign-key join columns start unindexed - those are the big wins here
-- (and what makes Q2/Q17/Q20 fast instead of pathological).

-- =====================================================================
-- Primary-key join targets (unindexed in the base build)
-- =====================================================================
CREATE INDEX IF NOT EXISTS ixtest_part_partkey      ON part(p_partkey);
CREATE INDEX IF NOT EXISTS ixtest_supplier_suppkey  ON supplier(s_suppkey);
CREATE INDEX IF NOT EXISTS ixtest_customer_custkey  ON customer(c_custkey);
CREATE INDEX IF NOT EXISTS ixtest_orders_orderkey   ON orders(o_orderkey);
CREATE INDEX IF NOT EXISTS ixtest_nation_nationkey  ON nation(n_nationkey);
CREATE INDEX IF NOT EXISTS ixtest_region_regionkey  ON region(r_regionkey);
CREATE INDEX IF NOT EXISTS ixtest_partsupp_pk       ON partsupp(ps_partkey, ps_suppkey);

-- =====================================================================
-- Foreign-key join columns
-- =====================================================================
-- lineitem FKs (l_orderkey already has the default index)
CREATE INDEX IF NOT EXISTS ixtest_lineitem_partkey  ON lineitem(l_partkey);
CREATE INDEX IF NOT EXISTS ixtest_lineitem_suppkey  ON lineitem(l_suppkey);
CREATE INDEX IF NOT EXISTS ixtest_lineitem_partsupp ON lineitem(l_partkey, l_suppkey);  -- Q9/Q17/Q20
-- partsupp FKs
CREATE INDEX IF NOT EXISTS ixtest_partsupp_partkey  ON partsupp(ps_partkey);            -- Q2/Q11/Q16
CREATE INDEX IF NOT EXISTS ixtest_partsupp_suppkey  ON partsupp(ps_suppkey);            -- Q2/Q11/Q20
-- supplier / nation FKs (orders.o_custkey & customer.c_nationkey already indexed)
CREATE INDEX IF NOT EXISTS ixtest_supplier_nationkey ON supplier(s_nationkey);          -- Q2/Q5/Q7/Q8/Q11/Q20/Q21
CREATE INDEX IF NOT EXISTS ixtest_nation_regionkey   ON nation(n_regionkey);            -- Q2/Q5/Q8

-- =====================================================================
-- Range / equality predicate columns
-- =====================================================================
-- dates (range scans)
CREATE INDEX IF NOT EXISTS ixtest_lineitem_shipdate    ON lineitem(l_shipdate);      -- Q1/Q6/Q7/Q14/Q15/Q20
CREATE INDEX IF NOT EXISTS ixtest_lineitem_receiptdate ON lineitem(l_receiptdate);   -- Q12
CREATE INDEX IF NOT EXISTS ixtest_lineitem_commitdate  ON lineitem(l_commitdate);    -- Q4/Q12/Q21
CREATE INDEX IF NOT EXISTS ixtest_orders_orderdate     ON orders(o_orderdate);       -- Q3/Q4/Q5/Q8/Q10
-- part attributes
CREATE INDEX IF NOT EXISTS ixtest_part_size         ON part(p_size);                 -- Q2/Q16
CREATE INDEX IF NOT EXISTS ixtest_part_brand        ON part(p_brand);                -- Q16/Q17/Q19
CREATE INDEX IF NOT EXISTS ixtest_part_container    ON part(p_container);            -- Q17/Q19
-- low-cardinality filters (included to measure their storage cost / usage)
CREATE INDEX IF NOT EXISTS ixtest_customer_mktseg   ON customer(c_mktsegment);       -- Q3
CREATE INDEX IF NOT EXISTS ixtest_orders_status     ON orders(o_orderstatus);        -- Q21
CREATE INDEX IF NOT EXISTS ixtest_lineitem_shipmode ON lineitem(l_shipmode);         -- Q12

-- =====================================================================
-- Covering / composite indexes (enable index-only scans)
-- =====================================================================
-- Q1/Q6-style aggregations over a shipdate range without touching the heap.
CREATE INDEX IF NOT EXISTS ixtest_lineitem_ship_cover
    ON lineitem(l_shipdate) INCLUDE (l_quantity, l_extendedprice, l_discount, l_tax);
-- Orders date+cust composite for the customer/orders/date join queries.
CREATE INDEX IF NOT EXISTS ixtest_orders_date_cust
    ON orders(o_orderdate, o_custkey);
