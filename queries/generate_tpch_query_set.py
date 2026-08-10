#!/usr/bin/env python3
"""
Generate the official TPC-H query set (Q1-Q22) as a harness corpus, from the
premade dbgen templates in ../tpch-dbgen/queries and ../tpch-dbgen/variants.

For each query it emits:
  queries/tpch/tpch-queries/qNN/base.sql        - the standard query
  queries/tpch/tpch-queries/qNN/v<k>_<kind>.sql - plan variants (same result)

A few files are pathologically slow at SF1 (Q17/Q20's correlated base and its
materialized wrapper - the schema has no index on the correlated columns) and go
to slow_queries/tpch/tpch-queries/ instead, so a normal sweep of queries/tpch
does not stall on them (see the SLOW set below).

The dbgen templates are qgen *templates*, not runnable SQL: they carry qgen
directives (:x, :o, :n) and substitution parameters (:1, :2, ...). This script:
  * strips the directives and the -- $ID$ comment,
  * substitutes :N with the TPC-H validation (qualification) parameters, so the
    output is reproducible,
  * applies the PostgreSQL-compatibility fixes the templates need (the biggest is
    `interval 'D' day (3)` -> `interval 'D' day`; PG rejects the field precision),
  * turns the `:n N` row-limit directive into a real `LIMIT N`,
  * uses the single-statement CTE form (variant 15a) for Q15, whose template is
    create view / select / drop view and cannot be one EXPLAIN statement,
  * wraps every query in EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON,
    BUFFERS) so it measures exactly like the rest of queries/tpch.

Variants keep the SAME result set as the base but aim for a different plan
(IN/EXISTS/join rewrites, decorrelation, FILTER aggregates, UNION ALL of
disjoint branches, and a MATERIALIZED-CTE wrapper generated for every query).

Usage:
  python3 queries/generate_tpch_query_set.py            # (re)generate the tree
  python3 queries/generate_tpch_query_set.py --check    # + validate on `tpch`:
        every file must execute, and every variant's multiset result must equal
        its base's. Needs psql access to a loaded `tpch` database.
"""

import os, re, sys, shutil, subprocess

HERE     = os.path.dirname(os.path.abspath(__file__))          # .../queries
REPO     = os.path.dirname(HERE)                                # repo root
SRC_Q    = os.path.join(REPO, "tpch-dbgen", "queries")
SRC_V    = os.path.join(REPO, "tpch-dbgen", "variants")
OUT_ROOT = os.path.join(HERE, "tpch", "tpch-queries")
# Pathologically slow files go here instead, so a normal sweep does not stall on
# them (run them on their own with `make run DIR=slow_queries/tpch/tpch-queries`).
SLOW_ROOT = os.path.join(REPO, "slow_queries", "tpch", "tpch-queries")

# (query number, variant kind) whose runtime is pathological at SF1: Q17/Q20's
# base and materialized forms correlate a subquery over columns this schema does
# NOT index (l_partkey / l_suppkey), so they blow past 900s at SF1 and would run
# for many hours at SF5. Q17's decorrelated variant stays in the main set. (Q2 is
# only moderately slow - ~1-2 min at SF1 - so it stays in the main set too.)
SLOW = {(17, "base"), (17, "materialized"),
        (20, "base"), (20, "materialized")}

EXPLAIN = "EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)"

# TPC-H validation (qualification) substitution parameters - the spec's fixed
# values, so the generated queries are reproducible run to run.
PARAMS = {
    1:  {1: "90"},
    2:  {1: "15", 2: "BRASS", 3: "EUROPE"},
    3:  {1: "BUILDING", 2: "1995-03-15"},
    4:  {1: "1993-07-01"},
    5:  {1: "ASIA", 2: "1994-01-01"},
    6:  {1: "1994-01-01", 2: "0.06", 3: "24"},
    7:  {1: "FRANCE", 2: "GERMANY"},
    8:  {1: "BRAZIL", 2: "AMERICA", 3: "ECONOMY ANODIZED STEEL"},
    9:  {1: "green"},
    10: {1: "1993-10-01"},
    11: {1: "GERMANY", 2: "0.0001"},
    12: {1: "MAIL", 2: "SHIP", 3: "1994-01-01"},
    13: {1: "special", 2: "requests"},
    14: {1: "1995-09-01"},
    15: {1: "1996-01-01"},
    16: {1: "Brand#45", 2: "MEDIUM POLISHED",
         3: "49", 4: "14", 5: "23", 6: "45", 7: "19", 8: "3", 9: "36", 10: "9"},
    17: {1: "Brand#23", 2: "MED BOX"},
    18: {1: "300"},
    19: {1: "Brand#12", 2: "Brand#23", 3: "Brand#34", 4: "1", 5: "10", 6: "20"},
    20: {1: "forest", 2: "1994-01-01", 3: "CANADA"},
    21: {1: "SAUDI ARABIA"},
    22: {1: "13", 2: "31", 3: "23", 4: "29", 5: "30", 6: "18", 7: "17"},
}

# `:n N` row limits (templates with :n -1 impose no limit).
LIMITS = {2: 100, 3: 10, 10: 20, 18: 100, 21: 100}

TITLES = {
    1: "Pricing Summary Report", 2: "Minimum Cost Supplier",
    3: "Shipping Priority", 4: "Order Priority Checking",
    5: "Local Supplier Volume", 6: "Forecasting Revenue Change",
    7: "Volume Shipping", 8: "National Market Share",
    9: "Product Type Profit Measure", 10: "Returned Item Reporting",
    11: "Important Stock Identification", 12: "Shipping Modes and Order Priority",
    13: "Customer Distribution", 14: "Promotion Effect",
    15: "Top Supplier", 16: "Parts/Supplier Relationship",
    17: "Small-Quantity-Order Revenue", 18: "Large Volume Customer",
    19: "Discounted Revenue", 20: "Potential Part Promotion",
    21: "Suppliers Who Kept Orders Waiting", 22: "Global Sales Opportunity",
}

# Q15's plain template is create-view/select/drop-view (3 statements); its
# variant 15a is the single-SELECT CTE form, which is what a one-statement
# EXPLAIN needs. Everything else comes from queries/N.sql.
BASE_SRC = {n: os.path.join(SRC_Q, f"{n}.sql") for n in range(1, 23)}
BASE_SRC[15] = os.path.join(SRC_V, "15a.sql")


def substitute(text, n):
    """Replace :N tokens with the query's validation parameters (highest first,
    so :10 is not clobbered by the :1 rule)."""
    def repl(m):
        return PARAMS[n][int(m.group(1))]
    return re.sub(r":(\d+)", repl, text)


def pg_fixes(text):
    # PG rejects the interval field precision `day (3)`; drop it.
    text = re.sub(r"\bday\s*\(\s*3\s*\)", "day", text)
    return text


def clean_template(path):
    """Strip qgen directives (:x, :o, :n) and comments, returning the bare query
    body (no trailing semicolon)."""
    body = []
    for line in open(path):
        s = line.strip()
        if s in (":x", ":o") or s.startswith(":n"):
            continue
        if s.startswith("--"):
            continue
        body.append(line.rstrip("\n"))
    txt = "\n".join(body).strip()
    return txt.rstrip(";").strip()


ORDER_BY_RE = re.compile(r"(?im)^order\s+by\b")


def split_order_by(body):
    """Return (pre, order_by_clause) splitting off the LAST top-level ORDER BY
    (top-level ones start at column 0 in these queries; subquery ones are
    indented). order_by_clause is '' when the query has none."""
    matches = list(ORDER_BY_RE.finditer(body))
    if not matches:
        return body.strip(), ""
    idx = matches[-1].start()
    return body[:idx].rstrip(), body[idx:].strip()


def materialized_variant(body):
    """A mechanical, always-equivalent variant: force the whole computation
    through a MATERIALIZED CTE, then read it back (keeps any ORDER BY outside so
    ordering/limit still apply)."""
    pre, order = split_order_by(body)
    v = "with _m as materialized (\n" + pre + "\n)\nselect * from _m"
    if order:
        v += "\n" + order
    return v


# Hand-authored structural variants. Each body uses :N placeholders (substituted
# with the same PARAMS as the base), starts at SELECT/WITH, keeps a top-level
# ORDER BY at column 0 when the base has one, and carries NO trailing ';'/LIMIT
# (added uniformly below). Every one is checked against its base under --check.
VARIANTS = {
    2: [("decorrelate", """\
with mincost (mpartkey, mn) as (
	select ps_partkey, min(ps_supplycost)
	from partsupp, supplier, nation, region
	where s_suppkey = ps_suppkey
		and s_nationkey = n_nationkey
		and n_regionkey = r_regionkey
		and r_name = ':3'
	group by ps_partkey
)
select
	s_acctbal, s_name, n_name, p_partkey, p_mfgr, s_address, s_phone, s_comment
from
	part, supplier, partsupp, nation, region, mincost
where
	p_partkey = ps_partkey
	and s_suppkey = ps_suppkey
	and p_size = :1
	and p_type like '%:2'
	and s_nationkey = n_nationkey
	and n_regionkey = r_regionkey
	and r_name = ':3'
	and mincost.mpartkey = p_partkey
	and ps_supplycost = mincost.mn
order by
	s_acctbal desc, n_name, s_name, p_partkey""")],

    4: [("in", """\
select
	o_orderpriority, count(*) as order_count
from
	orders
where
	o_orderdate >= date ':1'
	and o_orderdate < date ':1' + interval '3' month
	and o_orderkey in (
		select l_orderkey from lineitem where l_commitdate < l_receiptdate
	)
group by
	o_orderpriority
order by
	o_orderpriority""")],

    7: [("union_all", """\
select
	supp_nation, cust_nation, l_year, sum(volume) as revenue
from (
	select n1.n_name as supp_nation, n2.n_name as cust_nation,
		extract(year from l_shipdate) as l_year,
		l_extendedprice * (1 - l_discount) as volume
	from supplier, lineitem, orders, customer, nation n1, nation n2
	where s_suppkey = l_suppkey and o_orderkey = l_orderkey
		and c_custkey = o_custkey
		and s_nationkey = n1.n_nationkey and c_nationkey = n2.n_nationkey
		and n1.n_name = ':1' and n2.n_name = ':2'
		and l_shipdate between date '1995-01-01' and date '1996-12-31'
	union all
	select n1.n_name, n2.n_name, extract(year from l_shipdate),
		l_extendedprice * (1 - l_discount)
	from supplier, lineitem, orders, customer, nation n1, nation n2
	where s_suppkey = l_suppkey and o_orderkey = l_orderkey
		and c_custkey = o_custkey
		and s_nationkey = n1.n_nationkey and c_nationkey = n2.n_nationkey
		and n1.n_name = ':2' and n2.n_name = ':1'
		and l_shipdate between date '1995-01-01' and date '1996-12-31'
) as shipping
group by
	supp_nation, cust_nation, l_year
order by
	supp_nation, cust_nation, l_year""")],

    8: [("filter", """\
select
	o_year,
	sum(volume) filter (where nation = ':1') / sum(volume) as mkt_share
from (
	select extract(year from o_orderdate) as o_year,
		l_extendedprice * (1 - l_discount) as volume,
		n2.n_name as nation
	from part, supplier, lineitem, orders, customer, nation n1, nation n2, region
	where p_partkey = l_partkey and s_suppkey = l_suppkey
		and l_orderkey = o_orderkey and o_custkey = c_custkey
		and c_nationkey = n1.n_nationkey and n1.n_regionkey = r_regionkey
		and r_name = ':2' and s_nationkey = n2.n_nationkey
		and o_orderdate between date '1995-01-01' and date '1996-12-31'
		and p_type = ':3'
) as all_nations
group by
	o_year
order by
	o_year""")],

    11: [("cte_threshold", """\
with total (v) as (
	select sum(ps_supplycost * ps_availqty) * :2
	from partsupp, supplier, nation
	where ps_suppkey = s_suppkey and s_nationkey = n_nationkey and n_name = ':1'
)
select
	ps_partkey, sum(ps_supplycost * ps_availqty) as value
from
	partsupp, supplier, nation
where
	ps_suppkey = s_suppkey and s_nationkey = n_nationkey and n_name = ':1'
group by
	ps_partkey
having
	sum(ps_supplycost * ps_availqty) > (select v from total)
order by
	value desc""")],

    12: [("filter", """\
select
	l_shipmode,
	count(*) filter (where o_orderpriority in ('1-URGENT', '2-HIGH')) as high_line_count,
	count(*) filter (where o_orderpriority not in ('1-URGENT', '2-HIGH')) as low_line_count
from
	orders, lineitem
where
	o_orderkey = l_orderkey
	and l_shipmode in (':1', ':2')
	and l_commitdate < l_receiptdate
	and l_shipdate < l_commitdate
	and l_receiptdate >= date ':3'
	and l_receiptdate < date ':3' + interval '1' year
group by
	l_shipmode
order by
	l_shipmode""")],

    13: [("correlated", """\
select
	c_count, count(*) as custdist
from (
	select c_custkey,
		(select count(*) from orders
		 where o_custkey = c_custkey and o_comment not like '%:1%:2%') as c_count
	from customer
) as c_orders
group by
	c_count
order by
	custdist desc, c_count desc""")],

    14: [("filter", """\
select
	100.00 * sum(l_extendedprice * (1 - l_discount)) filter (where p_type like 'PROMO%')
		/ sum(l_extendedprice * (1 - l_discount)) as promo_revenue
from
	lineitem, part
where
	l_partkey = p_partkey
	and l_shipdate >= date ':1'
	and l_shipdate < date ':1' + interval '1' month""")],

    16: [("not_exists", """\
select
	p_brand, p_type, p_size, count(distinct ps_suppkey) as supplier_cnt
from
	partsupp, part
where
	p_partkey = ps_partkey
	and p_brand <> ':1'
	and p_type not like ':2%'
	and p_size in (:3, :4, :5, :6, :7, :8, :9, :10)
	and not exists (
		select 1 from supplier
		where s_suppkey = ps_suppkey and s_comment like '%Customer%Complaints%'
	)
group by
	p_brand, p_type, p_size
order by
	supplier_cnt desc, p_brand, p_type, p_size""")],

    17: [("decorrelate", """\
select
	sum(l_extendedprice) / 7.0 as avg_yearly
from
	lineitem, part,
	(select l_partkey as pk, 0.2 * avg(l_quantity) as thresh
	 from lineitem group by l_partkey) as avgq
where
	p_partkey = l_partkey
	and p_brand = ':1'
	and p_container = ':2'
	and avgq.pk = p_partkey
	and l_quantity < avgq.thresh""")],

    18: [("join", """\
select
	c_name, c_custkey, o_orderkey, o_orderdate, o_totalprice, sum(l_quantity)
from
	customer, orders, lineitem,
	(select l_orderkey from lineitem group by l_orderkey
	 having sum(l_quantity) > :1) as big
where
	big.l_orderkey = o_orderkey
	and c_custkey = o_custkey
	and o_orderkey = lineitem.l_orderkey
group by
	c_name, c_custkey, o_orderkey, o_orderdate, o_totalprice
order by
	o_totalprice desc, o_orderdate""")],

    19: [("union_all", """\
select sum(revenue) as revenue from (
	select l_extendedprice * (1 - l_discount) as revenue
	from lineitem, part
	where p_partkey = l_partkey and p_brand = ':1'
		and p_container in ('SM CASE', 'SM BOX', 'SM PACK', 'SM PKG')
		and l_quantity >= :4 and l_quantity <= :4 + 10
		and p_size between 1 and 5
		and l_shipmode in ('AIR', 'AIR REG') and l_shipinstruct = 'DELIVER IN PERSON'
	union all
	select l_extendedprice * (1 - l_discount)
	from lineitem, part
	where p_partkey = l_partkey and p_brand = ':2'
		and p_container in ('MED BAG', 'MED BOX', 'MED PKG', 'MED PACK')
		and l_quantity >= :5 and l_quantity <= :5 + 10
		and p_size between 1 and 10
		and l_shipmode in ('AIR', 'AIR REG') and l_shipinstruct = 'DELIVER IN PERSON'
	union all
	select l_extendedprice * (1 - l_discount)
	from lineitem, part
	where p_partkey = l_partkey and p_brand = ':3'
		and p_container in ('LG CASE', 'LG BOX', 'LG PACK', 'LG PKG')
		and l_quantity >= :6 and l_quantity <= :6 + 10
		and p_size between 1 and 15
		and l_shipmode in ('AIR', 'AIR REG') and l_shipinstruct = 'DELIVER IN PERSON'
) as branches""")],

    22: [("anti_join", """\
select
	cntrycode, count(*) as numcust, sum(c_acctbal) as totacctbal
from (
	select substring(c_phone from 1 for 2) as cntrycode, c_acctbal
	from customer left join orders on o_custkey = c_custkey
	where substring(c_phone from 1 for 2) in (':1', ':2', ':3', ':4', ':5', ':6', ':7')
		and c_acctbal > (
			select avg(c_acctbal) from customer
			where c_acctbal > 0.00
			and substring(c_phone from 1 for 2) in (':1', ':2', ':3', ':4', ':5', ':6', ':7')
		)
		and o_orderkey is null
) as custsale
group by
	cntrycode
order by
	cntrycode""")],
}


def compose(title, subtitle, body, n):
    """Wrap a (params-substituted, PG-fixed) body into the final EXPLAIN file,
    appending the query's LIMIT."""
    lim = LIMITS.get(n, -1)
    tail = f"\nlimit {lim}" if lim and lim > 0 else ""
    return (f"-- TPC-H Q{n}: {title} - {subtitle}\n"
            f"-- Generated from tpch-dbgen by generate_tpch_query_set.py "
            f"(validation params, PG fixes).\n"
            f"{EXPLAIN}\n{body}{tail};\n")


def build_bodies(n):
    """Return {'base': body, 'v1_kind': body, ...} of params-substituted,
    PG-fixed query bodies (no EXPLAIN, no trailing ';'/LIMIT)."""
    base = pg_fixes(substitute(clean_template(BASE_SRC[n]), n))
    out = {("base", None): base}
    # mechanical materialized-CTE variant for every query
    out[("materialized", "materialized")] = materialized_variant(base)
    # hand-authored structural variants
    for kind, tmpl in VARIANTS.get(n, []):
        out[(kind, kind)] = pg_fixes(substitute(tmpl.strip(), n))
    return out


def generate():
    for root in (OUT_ROOT, SLOW_ROOT):
        if os.path.isdir(root):
            shutil.rmtree(root)
    main_n = slow_n = 0
    for n in range(1, 23):
        bodies = build_bodies(n)
        k = 1
        for (kind, _), body in bodies.items():
            if kind == "base":
                fname, sub = "base.sql", "base"
            else:
                fname, sub = f"v{k}_{kind}.sql", f"variant: {kind}"
                k += 1
            root = SLOW_ROOT if (n, kind) in SLOW else OUT_ROOT
            qdir = os.path.join(root, f"q{n:02d}")
            os.makedirs(qdir, exist_ok=True)
            with open(os.path.join(qdir, fname), "w") as fh:
                fh.write(compose(TITLES[n], sub, body, n))
            if root is SLOW_ROOT:
                slow_n += 1
            else:
                main_n += 1
    print(f"generated {main_n} files under {os.path.relpath(OUT_ROOT, REPO)}/ "
          f"and {slow_n} slow files under {os.path.relpath(SLOW_ROOT, REPO)}/")
    return main_n + slow_n


# --------------------------------------------------------------------- --check
DB = os.environ.get("DB_NAME", "tpch")


def psql(sql):
    r = subprocess.run(["psql", "-d", DB, "-tAX", "-c", sql],
                       capture_output=True, text=True)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def fingerprint(body):
    """(count, md5) of a body's result multiset, order-independent (so ORDER BY
    ties and plan differences do not cause false mismatches). LIMIT is NOT
    applied - equivalence is checked on the full result set."""
    q = ("select count(*), "
         "md5(coalesce(string_agg(_r::text, '|' order by _r::text), '')) "
         f"from (\n{body}\n) _r")
    rc, out, err = psql(q)
    if rc != 0:
        return None, err.splitlines()[-1] if err else "error"
    return out.replace("|", " / "), None


def check():
    ok = bad = 0
    for n in range(1, 23):
        bodies = build_bodies(n)
        base_body = bodies[("base", None)]
        base_fp, base_err = fingerprint(base_body)
        if base_err:
            print(f"  Q{n:02d} base            FAIL to execute: {base_err}")
            bad += 1
            continue
        print(f"  Q{n:02d} base            {base_fp}")
        ok += 1
        for (kind, _), body in bodies.items():
            if kind == "base":
                continue
            fp, err = fingerprint(body)
            if err:
                print(f"        {kind:14s} FAIL to execute: {err}")
                bad += 1
            elif fp != base_fp:
                print(f"        {kind:14s} MISMATCH: {fp}  (base {base_fp})")
                bad += 1
            else:
                print(f"        {kind:14s} ok")
                ok += 1
    print(f"\n--check: {ok} ok, {bad} bad")
    return bad == 0


if __name__ == "__main__":
    generate()
    if "--check" in sys.argv:
        print(f"\nvalidating against database '{DB}' ...")
        sys.exit(0 if check() else 1)
