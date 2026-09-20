#!/usr/bin/env python3
"""
Generate one benchmark query per PostgreSQL Chapter 9 operation.

Design decisions baked into the generated SQL:

  * NO LIMIT     - every query scans the whole lineitem table (~6M rows).
  * NO aggregate - an aggregate would add its own per-row cost to the
                   measurement. Instead each query is wrapped in
                   EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS),
                   which executes the plan and evaluates the target list but
                   discards the rows server-side, so nothing crosses the wire.
                   SUMMARY ON prints Planning/Execution Time and BUFFERS prints
                   block counts; the runner parses both into the per-run
                   samples CSV. Neither changes what is executed, and the cost
                   of both is below measurement noise.
                   Measured on this machine (6M rows, trivial projection):
                       EXPLAIN(ANALYZE, TIMING OFF) ..  364 ms
                       EXPLAIN(ANALYZE)             ..  549 ms
                       plain SELECT -> /dev/null     .. 2445 ms
  * ONE OPERATION PER FILE - so each file yields an energy number for a
                   single operator/function rather than a mixed bag.

Every query is read-only (pure SELECT under EXPLAIN); nothing is written.

Usage:  python3 build/generate_tpch_function_queries.py
Re-run it after editing SPEC to regenerate queries/tpch/Functions/.
"""

import os
import shutil

REPO     = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # repo root (this file is in build/)
OUT_ROOT = os.path.join(REPO, "queries", "tpch", "Functions")

# A few queries are pathologically slow. They are written to a SEPARATE
# top-level directory instead of Functions, so a normal sweep never trips over
# them and they can be run on their own: `make run DIR=queries/slow`. Add
# (section_dir, op_name) pairs here to move more operations out of the main set.
#   - all_subquery ("<> ALL (subquery)"): a Materialize subplan is re-scanned
#     once per outer row -> ~72s at SF1, hours at SF20.
#   - frame_exclude_ties / frame_range_running: a RANGE frame ending at CURRENT
#     ROW spans the whole peer group, and with l_shipdate carrying ~2.5k rows
#     per date the aggregate is recomputed per row (no moving-aggregate) -> the
#     running sum is effectively O(n^2). A single run did not finish in 8h+ at
#     SF1; other window frames (ROWS/GROUPS/bounded) are fine and stay in place.
LONG_ROOT = os.path.join(REPO, "queries", "slow", "tpch")
LONG_RUNNING = {
    ("09-24_subquery", "all_subquery"),
    ("09-22_window", "frame_exclude_ties"),
    ("09-22_window", "frame_range_running"),
}

HEADER = ("EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)")

# Each section: (directory, human title, note, [(filename, expression_or_RAW), ...])
# A plain expression is rendered as:  SELECT <expr> FROM lineitem;
# "RAW:<sql>" supplies the whole statement body instead.
SPEC = []

# ----------------------------------------------------------------- baselines
SPEC.append(("00_baseline", "Baselines (no Chapter 9 operation applied)",
 "Subtract the baseline whose input column type matches the query under test:\n"
 "-- scanning a wide text column costs more than a narrow int, so comparing a\n"
 "-- numeric operation against the text baseline can make it look free.", [
    ("int",     "l_orderkey"),
    ("numeric", "l_quantity"),
    ("text",    "l_comment"),
    ("date",    "l_shipdate"),
    ("char",    "l_shipmode"),
]))

# ----------------------------------------------------------------- 9.1
SPEC.append(("09-01_logical", "9.1 Logical Operators", None, [
    ("and", "(l_discount > 0.02) AND (l_quantity < 30)"),
    ("or",  "(l_discount > 0.02) OR (l_quantity < 30)"),
    ("not", "NOT (l_discount > 0.02)"),
]))

# ----------------------------------------------------------------- 9.2
SPEC.append(("09-02_comparison", "9.2 Comparison Functions and Operators", None, [
    ("lt",               "l_quantity < 30"),
    ("gt",               "l_quantity > 30"),
    ("le",               "l_quantity <= 30"),
    ("ge",               "l_quantity >= 30"),
    ("eq",               "l_quantity = 30"),
    ("ne",               "l_quantity <> 30"),
    ("between",          "l_quantity BETWEEN 5 AND 40"),
    ("not_between",      "l_quantity NOT BETWEEN 5 AND 40"),
    ("between_symmetric","l_quantity BETWEEN SYMMETRIC 40 AND 5"),
    ("is_null",          "l_comment IS NULL"),
    ("is_not_null",      "l_comment IS NOT NULL"),
    ("is_distinct_from", "l_quantity IS DISTINCT FROM 30"),
    ("is_not_distinct_from", "l_quantity IS NOT DISTINCT FROM 30"),
    ("greatest",         "greatest(l_quantity, l_tax)"),
    ("least",            "least(l_quantity, l_tax)"),
    ("num_nonnulls",     "num_nonnulls(l_quantity, l_extendedprice)"),
    ("num_nulls",        "num_nulls(l_quantity, l_extendedprice)"),
]))

# ----------------------------------------------------------------- 9.3
SPEC.append(("09-03_math", "9.3 Mathematical Functions and Operators",
 "Several operations appear in both a numeric and a float8 variant: numeric is\n"
 "-- arbitrary-precision software arithmetic, float8 is hardware, so the pair\n"
 "-- shows the energy cost of the type choice for the same operation.", [
    ("add",            "l_quantity + l_tax"),
    ("subtract",       "l_quantity - l_tax"),
    ("multiply",       "l_quantity * l_tax"),
    ("divide",         "l_extendedprice / l_quantity"),
    ("modulo",         "l_orderkey % 7"),
    ("exponent",       "l_quantity ^ 2"),
    ("unary_minus",    "- l_quantity"),
    ("abs",            "abs(l_quantity - 25)"),
    ("ceil",           "ceil(l_extendedprice / 7)"),
    ("floor",          "floor(l_extendedprice / 7)"),
    ("round",          "round(l_extendedprice / 7)"),
    ("round_scale",    "round(l_extendedprice / 7, 2)"),
    ("trunc",          "trunc(l_extendedprice / 7)"),
    ("trunc_scale",    "trunc(l_extendedprice / 7, 2)"),
    ("sign",           "sign(l_quantity - 25)"),
    ("mod_fn",         "mod(l_orderkey, 7)"),
    ("div_fn",         "div(l_extendedprice, l_quantity)"),
    ("gcd",            "gcd(l_orderkey, l_partkey)"),
    ("lcm",            "lcm(l_linenumber::bigint, 12)"),
    ("factorial",      "factorial(l_linenumber)"),
    ("width_bucket",   "width_bucket(l_quantity, 0, 50, 10)"),
    ("random",         "random()"),
    ("min_scale",      "min_scale(l_extendedprice)"),
    ("trim_scale",     "trim_scale(l_extendedprice)"),
    # numeric vs float8 pairs
    ("sqrt_numeric",   "sqrt(l_extendedprice)"),
    ("sqrt_float8",    "sqrt(l_extendedprice::float8)"),
    ("ln_numeric",     "ln(l_quantity)"),
    ("ln_float8",      "ln(l_quantity::float8)"),
    ("exp_numeric",    "exp(l_discount)"),
    ("exp_float8",     "exp(l_discount::float8)"),
    ("log10_numeric",  "log(l_quantity)"),
    ("log10_float8",   "log(l_quantity::float8)"),
    ("log_base",       "log(2.0, l_quantity)"),
    ("power_numeric",  "power(l_quantity, 2)"),
    ("power_float8",   "power(l_quantity::float8, 2)"),
    ("add_float8",     "l_quantity::float8 + l_tax::float8"),
    ("multiply_float8","l_quantity::float8 * l_tax::float8"),
    ("cbrt",           "cbrt(l_extendedprice::float8)"),
    ("degrees",        "degrees(l_discount::float8)"),
    ("radians",        "radians(l_quantity::float8)"),
    ("sin",            "sin(l_discount::float8)"),
    ("cos",            "cos(l_discount::float8)"),
    ("tan",            "tan(l_discount::float8)"),
    ("asin",           "asin(l_discount::float8)"),
    ("acos",           "acos(l_discount::float8)"),
    ("atan",           "atan(l_quantity::float8)"),
    ("atan2",          "atan2(l_quantity::float8, l_tax::float8 + 1)"),
    ("sinh",           "sinh(l_discount::float8)"),
    ("cosh",           "cosh(l_discount::float8)"),
    ("tanh",           "tanh(l_discount::float8)"),
    ("asinh",          "asinh(l_quantity::float8)"),
    ("acosh",          "acosh(l_quantity::float8 + 1)"),
    ("atanh",          "atanh(l_discount::float8)"),
    ("scale",          "scale(l_extendedprice)"),
    ("pi",             "pi() * l_quantity::float8"),
]))

# ----------------------------------------------------------------- 9.4
SPEC.append(("09-04_string", "9.4 String Functions and Operators", None, [
    ("concat_op",     "l_comment || 'x'"),
    ("concat_fn",     "concat(l_comment, 'x')"),
    ("concat_ws",     "concat_ws('-', l_comment, l_shipmode)"),
    ("length",        "length(l_comment)"),
    ("char_length",   "char_length(l_comment)"),
    ("octet_length",  "octet_length(l_comment)"),
    ("bit_length",    "bit_length(l_comment)"),
    ("lower",         "lower(l_comment)"),
    ("upper",         "upper(l_comment)"),
    ("initcap",       "initcap(l_comment)"),
    ("substring",     "substring(l_comment FROM 2 FOR 8)"),
    ("substr",        "substr(l_comment, 2, 8)"),
    ("left",          "left(l_comment, 8)"),
    ("right",         "right(l_comment, 8)"),
    ("reverse",       "reverse(l_comment)"),
    ("repeat",        "repeat(l_comment, 2)"),
    ("replace",       "replace(l_comment, 'a', 'x')"),
    ("overlay",       "overlay(l_comment PLACING 'xx' FROM 2 FOR 2)"),
    ("position",      "position('the' IN l_comment)"),
    ("strpos",        "strpos(l_comment, 'the')"),
    ("btrim",         "btrim(l_shipmode)"),
    ("ltrim",         "ltrim(l_shipmode)"),
    ("rtrim",         "rtrim(l_shipmode)"),
    ("trim_both",     "trim(BOTH ' ' FROM l_shipmode)"),
    ("lpad",          "lpad(l_comment, 50, '.')"),
    ("rpad",          "rpad(l_comment, 50, '.')"),
    ("split_part",    "split_part(l_comment, ' ', 2)"),
    ("starts_with",   "starts_with(l_comment, 'the')"),
    ("translate",     "translate(l_comment, 'abc', 'xyz')"),
    ("ascii",         "ascii(l_comment)"),
    ("chr",           "chr(65 + (l_linenumber % 26))"),
    ("md5",           "md5(l_comment)"),
    ("format",        "format('%s-%s', l_comment, l_linenumber)"),
    ("quote_literal", "quote_literal(l_comment)"),
    ("quote_ident",   "quote_ident(l_comment)"),
    ("to_hex",        "to_hex(l_orderkey)"),
    ("cast_text",     "l_orderkey::text"),
]))

# ----------------------------------------------------------------- 9.5
SPEC.append(("09-05_binary_string", "9.5 Binary String Functions and Operators", None, [
    ("cast_bytea",       "l_comment::bytea"),
    ("octet_length",     "octet_length(l_comment::bytea)"),
    ("concat_bytea",     "l_comment::bytea || 'x'::bytea"),
    ("substring_bytea",  "substring(l_comment::bytea FROM 2 FOR 8)"),
    ("get_byte",         "get_byte(l_comment::bytea, 2)"),
    ("set_byte",         "set_byte(l_comment::bytea, 2, 65)"),
    ("md5_bytea",        "md5(l_comment::bytea)"),
    ("sha224",           "sha224(l_comment::bytea)"),
    ("sha256",           "sha256(l_comment::bytea)"),
    ("sha384",           "sha384(l_comment::bytea)"),
    ("sha512",           "sha512(l_comment::bytea)"),
    ("encode_hex",       "encode(l_comment::bytea, 'hex')"),
    ("encode_base64",    "encode(l_comment::bytea, 'base64')"),
    ("encode_escape",    "encode(l_comment::bytea, 'escape')"),
    ("decode_hex",       "decode(md5(l_comment), 'hex')"),
]))

# ----------------------------------------------------------------- 9.6
SPEC.append(("09-06_bit_string", "9.6 Bit String Functions and Operators", None, [
    ("cast_bit",     "l_orderkey::bit(32)"),
    ("and",          "l_orderkey::bit(32) & l_partkey::bit(32)"),
    ("or",           "l_orderkey::bit(32) | l_partkey::bit(32)"),
    ("xor",          "l_orderkey::bit(32) # l_partkey::bit(32)"),
    ("not",          "~ l_orderkey::bit(32)"),
    ("shift_left",   "l_orderkey::bit(32) << 3"),
    ("shift_right",  "l_orderkey::bit(32) >> 3"),
    ("concat_bit",   "l_orderkey::bit(32) || l_linenumber::bit(8)"),
    ("length_bit",   "length(l_orderkey::bit(32))"),
    ("bit_count",    "bit_count(l_orderkey::bit(32))"),
    ("get_bit",      "get_bit(l_orderkey::bit(32), 3)"),
    ("set_bit",      "set_bit(l_orderkey::bit(32), 3, 1)"),
    ("substring_bit","substring(l_orderkey::bit(32) FROM 2 FOR 8)"),
    ("overlay_bit",  "overlay(l_orderkey::bit(32) PLACING b'11' FROM 2)"),
]))

# ----------------------------------------------------------------- 9.7
SPEC.append(("09-07_pattern_matching", "9.7 Pattern Matching",
 "The like/regex pairs use equivalent patterns so LIKE, SIMILAR TO and POSIX\n"
 "-- regex can be compared directly on identical work.", [
    ("like",                 "l_comment LIKE '%the%'"),
    ("not_like",             "l_comment NOT LIKE '%the%'"),
    ("like_prefix",          "l_comment LIKE 'the%'"),
    ("ilike",                "l_comment ILIKE '%the%'"),
    ("not_ilike",            "l_comment NOT ILIKE '%the%'"),
    ("similar_to",           "l_comment SIMILAR TO '%the%'"),
    ("regex_match",          "l_comment ~ 'the'"),
    ("regex_match_ci",       "l_comment ~* 'the'"),
    ("regex_not_match",      "l_comment !~ 'the'"),
    ("regex_not_match_ci",   "l_comment !~* 'the'"),
    ("regex_anchored",       "l_comment ~ '^the'"),
    ("regex_alternation",    "l_comment ~ '(the|and|for)'"),
    ("regex_backtrack",      "l_comment ~ '^[a-z]+ .*(ing|ed)( .*)?$'"),
    ("regex_charclass",      "l_comment ~ '[[:digit:]]'"),
    ("regexp_replace",       "regexp_replace(l_comment, 'the', 'X')"),
    ("regexp_replace_global","regexp_replace(l_comment, 'the', 'X', 'g')"),
    ("regexp_match",         "regexp_match(l_comment, '(the)')"),
    ("regexp_count",         "regexp_count(l_comment, 'the')"),
    ("regexp_like",          "regexp_like(l_comment, 'the')"),
    ("regexp_instr",         "regexp_instr(l_comment, 'the')"),
    ("regexp_substr",        "regexp_substr(l_comment, 'the')"),
    ("regexp_split_to_array","regexp_split_to_array(l_comment, ' ')"),
    ("substring_regex",      "substring(l_comment FROM '(the)')"),
]))

# ----------------------------------------------------------------- 9.8
SPEC.append(("09-08_formatting", "9.8 Data Type Formatting Functions", None, [
    ("to_char_date",      "to_char(l_shipdate, 'YYYY-MM-DD')"),
    ("to_char_date_long", "to_char(l_shipdate, 'Day, DD Month YYYY')"),
    ("to_char_numeric",   "to_char(l_extendedprice, '9999999D99')"),
    ("to_char_int",       "to_char(l_orderkey, '9999999')"),
    ("to_char_timestamp", "to_char(l_shipdate::timestamp, 'YYYY-MM-DD HH24:MI:SS')"),
    ("to_date",           "to_date(to_char(l_shipdate, 'YYYY-MM-DD'), 'YYYY-MM-DD')"),
    ("to_number",         "to_number(to_char(l_extendedprice, '9999999D99'), '9999999D99')"),
    ("to_timestamp",      "to_timestamp(l_orderkey)"),
]))

# ----------------------------------------------------------------- 9.9
SPEC.append(("09-09_datetime", "9.9 Date/Time Functions and Operators", None, [
    ("date_minus_date",   "l_receiptdate - l_shipdate"),
    ("date_plus_int",     "l_shipdate + 7"),
    ("date_minus_int",    "l_shipdate - 7"),
    ("date_plus_interval","l_shipdate + INTERVAL '1 month'"),
    ("age_two_args",      "age(l_receiptdate, l_shipdate)"),
    ("extract_year",      "extract(YEAR FROM l_shipdate)"),
    ("extract_month",     "extract(MONTH FROM l_shipdate)"),
    ("extract_day",       "extract(DAY FROM l_shipdate)"),
    ("extract_dow",       "extract(DOW FROM l_shipdate)"),
    ("extract_doy",       "extract(DOY FROM l_shipdate)"),
    ("extract_quarter",   "extract(QUARTER FROM l_shipdate)"),
    ("extract_week",      "extract(WEEK FROM l_shipdate)"),
    ("extract_epoch",     "extract(EPOCH FROM l_shipdate)"),
    ("date_part",         "date_part('year', l_shipdate)"),
    ("date_trunc_month",  "date_trunc('month', l_shipdate::timestamp)"),
    ("date_trunc_day",    "date_trunc('day', l_shipdate::timestamp)"),
    ("date_bin",          "date_bin(INTERVAL '7 days', l_shipdate::timestamp, TIMESTAMP '1992-01-01')"),
    ("make_date",         "make_date(1995, 1 + (l_linenumber % 12), 1)"),
    ("isfinite",          "isfinite(l_shipdate)"),
    ("justify_days",      "justify_days(age(l_receiptdate, l_shipdate))"),
    ("overlaps",          "(l_shipdate, l_receiptdate) OVERLAPS (DATE '1995-01-01', DATE '1995-12-31')"),
    ("cast_timestamp",    "l_shipdate::timestamp"),
    ("at_time_zone",      "l_shipdate::timestamp AT TIME ZONE 'UTC'"),
    ("make_timestamp",    "make_timestamp(1995, 1 + (l_linenumber % 12), 1, 12, 0, 0)"),
    ("make_interval",     "make_interval(days => l_linenumber)"),
    ("date_add_time",     "l_shipdate + TIME '12:00'"),
]))

# ----------------------------------------------------------------- 9.11
SPEC.append(("09-11_geometric", "9.11 Geometric Functions and Operators",
 "Geometry is synthesised from numeric columns; nothing is stored.", [
    ("point_make",         "point(l_quantity::float8, l_tax::float8)"),
    ("point_distance",     "point(l_quantity::float8, l_tax::float8) <-> point(0, 0)"),
    ("point_add",          "point(l_quantity::float8, l_tax::float8) + point(1, 1)"),
    ("point_mul",          "point(l_quantity::float8, l_tax::float8) * point(2, 2)"),
    ("box_make",           "box(point(0, 0), point(l_quantity::float8 + 1, l_tax::float8 + 1))"),
    ("box_area",           "area(box(point(0, 0), point(l_quantity::float8 + 1, l_tax::float8 + 1)))"),
    ("box_center",         "center(box(point(0, 0), point(l_quantity::float8 + 1, l_tax::float8 + 1)))"),
    ("box_contains_point", "box(point(0, 0), point(l_quantity::float8 + 1, l_tax::float8 + 1)) @> point(1, 0.5)"),
    ("box_overlaps",       "box(point(0, 0), point(l_quantity::float8 + 1, l_tax::float8 + 1)) && box(point(0, 0), point(5, 5))"),
    ("circle_make",        "circle(point(l_quantity::float8, l_tax::float8), 2)"),
    ("circle_area",        "area(circle(point(l_quantity::float8, l_tax::float8), 2))"),
    ("lseg_make",          "lseg(point(0, 0), point(l_quantity::float8, l_tax::float8))"),
    ("lseg_length",        "length(lseg(point(0, 0), point(l_quantity::float8, l_tax::float8)))"),
]))

# ----------------------------------------------------------------- 9.12
SPEC.append(("09-12_network", "9.12 Network Address Functions and Operators",
 "Addresses are synthesised from l_orderkey; nothing is stored.", [
    ("inet_cast",        "('10.0.0.0'::inet + (l_orderkey % 16777216))"),
    ("inet_add",         "('10.0.0.0'::inet + (l_orderkey % 16777216)) + 1"),
    ("inet_sub_int",     "('10.0.0.1'::inet + (l_orderkey % 16777216)) - 1"),
    ("inet_sub_inet",    "('10.0.0.0'::inet + (l_orderkey % 16777216)) - '10.0.0.0'::inet"),
    ("contained_by",     "('10.0.0.0'::inet + (l_orderkey % 16777216)) << '10.0.0.0/8'::inet"),
    ("contained_by_eq",  "('10.0.0.0'::inet + (l_orderkey % 16777216)) <<= '10.0.0.0/8'::inet"),
    ("contains",         "'10.0.0.0/8'::inet >> ('10.0.0.0'::inet + (l_orderkey % 16777216))"),
    ("overlaps",         "('10.0.0.0'::inet + (l_orderkey % 16777216)) && '10.0.0.0/8'::inet"),
    ("host",             "host('10.0.0.0'::inet + (l_orderkey % 16777216))"),
    ("masklen",          "masklen('10.0.0.0'::inet + (l_orderkey % 16777216))"),
    ("network",          "network(('10.0.0.0'::inet + (l_orderkey % 16777216)))"),
    ("broadcast",        "broadcast(('10.0.0.0'::inet + (l_orderkey % 16777216)))"),
    ("abbrev",           "abbrev(('10.0.0.0'::inet + (l_orderkey % 16777216)))"),
    ("set_masklen",      "set_masklen(('10.0.0.0'::inet + (l_orderkey % 16777216)), 24)"),
    ("family",           "family(('10.0.0.0'::inet + (l_orderkey % 16777216)))"),
    ("hostmask",         "hostmask(('10.0.0.0/24'::inet))"),
    ("netmask",          "netmask(('10.0.0.0/24'::inet))"),
    ("macaddr_cast",     "to_hex(l_orderkey % 16777216)"),
]))

# ----------------------------------------------------------------- 9.13
SPEC.append(("09-13_text_search", "9.13 Text Search Functions and Operators",
 "WARNING: the heaviest section. Parsing each row into a tsvector with no index\n"
 "-- costs roughly 25s per run over the full 6M rows, so a RUNS=10 sweep of this\n"
 "-- directory alone takes a long time. Consider RUNS=2 or 3 here.", [
    ("to_tsvector",           "to_tsvector('english', l_comment)"),
    ("to_tsvector_simple",    "to_tsvector('simple', l_comment)"),
    ("to_tsquery",            "to_tsquery('english', 'final')"),
    ("plainto_tsquery",       "plainto_tsquery('english', l_comment)"),
    ("phraseto_tsquery",      "phraseto_tsquery('english', l_comment)"),
    ("websearch_to_tsquery",  "websearch_to_tsquery('english', l_comment)"),
    ("match",                 "to_tsvector('english', l_comment) @@ to_tsquery('english', 'final & requests')"),
    ("ts_rank",               "ts_rank(to_tsvector('english', l_comment), to_tsquery('english', 'final'))"),
    ("ts_headline",           "ts_headline('english', l_comment, to_tsquery('english', 'final'))"),
    ("setweight",             "setweight(to_tsvector('english', l_comment), 'A')"),
    ("strip",                 "strip(to_tsvector('english', l_comment))"),
    ("length_tsvector",       "length(to_tsvector('english', l_comment))"),
    ("numnode",               "numnode(plainto_tsquery('english', l_comment))"),
]))

# ----------------------------------------------------------------- 9.14
SPEC.append(("09-14_uuid", "9.14 UUID Functions",
 "Note: uuidv4()/uuidv7() are PostgreSQL 18 additions and do not exist on the\n"
 "-- 16.14 server this was verified against; gen_random_uuid() is the v4 equivalent.", [
    ("gen_random_uuid", "gen_random_uuid()"),
    ("uuid_from_md5",   "md5(l_comment)::uuid"),
    ("uuid_to_text",    "gen_random_uuid()::text"),
]))

# ----------------------------------------------------------------- 9.15
SPEC.append(("09-15_xml", "9.15 XML Functions", None, [
    ("xmlelement",          "xmlelement(name item, l_comment)"),
    ("xmlelement_attrs",    "xmlelement(name item, xmlattributes(l_orderkey AS key), l_comment)"),
    ("xmlforest",           "xmlforest(l_orderkey AS key, l_comment AS comment)"),
    ("xmlconcat",           "xmlconcat(xmlelement(name a, l_orderkey), xmlelement(name b, l_comment))"),
    # An XML comment may not contain "--" or end in "-", and l_comment does
    # contain "--", so the input is sanitised first. The translate() cost is
    # therefore included in this measurement.
    ("xmlcomment",          "xmlcomment(translate(l_comment, '-', '_'))"),
    ("xmlpi",               "xmlpi(name php, l_comment)"),
    ("xml_is_well_formed",  "xml_is_well_formed(xmlelement(name item, l_comment)::text)"),
    ("xml_to_text",         "xmlelement(name item, l_comment)::text"),
    ("xpath",               "xpath('/item/text()', xmlelement(name item, l_comment))"),
]))

# ----------------------------------------------------------------- 9.16
SPEC.append(("09-16_json", "9.16 JSON Functions and Operators", None, [
    ("to_json",             "to_json(l_comment)"),
    ("to_jsonb",            "to_jsonb(l_comment)"),
    ("row_to_json",         "row_to_json(row(l_orderkey, l_comment))"),
    ("json_build_object",   "json_build_object('k', l_orderkey, 'c', l_comment)"),
    ("jsonb_build_object",  "jsonb_build_object('k', l_orderkey, 'c', l_comment)"),
    ("json_build_array",    "json_build_array(l_orderkey, l_comment)"),
    ("jsonb_build_array",   "jsonb_build_array(l_orderkey, l_comment)"),
    ("jsonb_to_text",       "jsonb_build_object('k', l_orderkey, 'c', l_comment)::text"),
    ("arrow_object",        "jsonb_build_object('k', l_orderkey, 'c', l_comment) -> 'c'"),
    ("arrow_text",          "jsonb_build_object('k', l_orderkey, 'c', l_comment) ->> 'c'"),
    ("path_extract",        "jsonb_build_object('k', l_orderkey, 'c', l_comment) #> '{c}'"),
    ("path_extract_text",   "jsonb_build_object('k', l_orderkey, 'c', l_comment) #>> '{c}'"),
    ("contains",            "jsonb_build_object('k', l_orderkey, 'c', l_comment) @> '{\"k\": 1}'::jsonb"),
    ("key_exists",          "jsonb_build_object('k', l_orderkey, 'c', l_comment) ? 'c'"),
    ("jsonb_set",           "jsonb_set(jsonb_build_object('k', l_orderkey, 'c', l_comment), '{c}', '\"x\"')"),
    ("jsonb_insert",        "jsonb_insert(jsonb_build_object('k', l_orderkey), '{n}', '\"x\"')"),
    ("jsonb_strip_nulls",   "jsonb_strip_nulls(jsonb_build_object('k', l_orderkey, 'c', l_comment))"),
    ("jsonb_pretty",        "jsonb_pretty(jsonb_build_object('k', l_orderkey, 'c', l_comment))"),
    ("jsonb_typeof",        "jsonb_typeof(to_jsonb(l_comment))"),
    ("jsonb_array_length",  "jsonb_array_length(jsonb_build_array(l_orderkey, l_comment))"),
    ("jsonb_path_query",    "jsonb_path_query_first(jsonb_build_object('k', l_orderkey), '$.k')"),
    ("jsonb_path_exists",   "jsonb_path_exists(jsonb_build_object('k', l_orderkey), '$.k')"),
    # jsonpath predicate operators (@? / @@) and the '?' form.
    ("jsonpath_exists_op",  "jsonb_build_object('k', l_orderkey) @? '$.k ? (@ > 0)'"),
    ("jsonpath_match_op",   "jsonb_build_object('k', l_orderkey) @@ '$.k > 0'"),
    ("jsonb_path_query_array", "jsonb_path_query_array(jsonb_build_object('k', l_orderkey), '$.k')"),
    ("jsonb_object_keys_arr","(SELECT array_agg(k) FROM jsonb_object_keys(jsonb_build_object('k', l_orderkey, 'c', l_comment)) AS k)"),
]))

# ----------------------------------------------------------------- 9.18
SPEC.append(("09-18_conditional", "9.18 Conditional Expressions", None, [
    ("case_simple",   "CASE l_returnflag WHEN 'A' THEN 1 WHEN 'R' THEN 2 ELSE 3 END"),
    ("case_searched", "CASE WHEN l_discount > 0.05 THEN 1 WHEN l_discount > 0.02 THEN 2 ELSE 3 END"),
    ("coalesce",      "coalesce(l_comment, 'none')"),
    ("nullif",        "nullif(l_returnflag, 'N')"),
]))

# ----------------------------------------------------------------- 9.19
SPEC.append(("09-19_array", "9.19 Array Functions and Operators", None, [
    ("array_construct",   "ARRAY[l_orderkey, l_partkey]"),
    ("array_concat_op",   "ARRAY[l_orderkey] || ARRAY[l_partkey]"),
    ("array_append",      "array_append(ARRAY[l_orderkey], l_partkey)"),
    ("array_prepend",     "array_prepend(l_orderkey, ARRAY[l_partkey])"),
    ("array_cat",         "array_cat(ARRAY[l_orderkey], ARRAY[l_partkey])"),
    ("array_length",      "array_length(ARRAY[l_orderkey, l_partkey], 1)"),
    ("cardinality",       "cardinality(ARRAY[l_orderkey, l_partkey])"),
    ("array_ndims",       "array_ndims(ARRAY[l_orderkey, l_partkey])"),
    ("array_dims",        "array_dims(ARRAY[l_orderkey, l_partkey])"),
    ("array_position",    "array_position(ARRAY[l_orderkey, l_partkey], l_partkey)"),
    ("array_positions",   "array_positions(ARRAY[l_orderkey, l_partkey], l_partkey)"),
    ("array_remove",      "array_remove(ARRAY[l_orderkey, l_partkey], l_partkey)"),
    ("array_replace",     "array_replace(ARRAY[l_orderkey, l_partkey], l_partkey, 0)"),
    ("array_to_string",   "array_to_string(ARRAY[l_orderkey, l_partkey], ',')"),
    ("string_to_array",   "string_to_array(l_comment, ' ')"),
    ("array_contains",    "ARRAY[l_orderkey, l_partkey] @> ARRAY[l_partkey]"),
    ("array_overlap",     "ARRAY[l_orderkey, l_partkey] && ARRAY[l_partkey]"),
    ("array_subscript",   "(ARRAY[l_orderkey, l_partkey])[1]"),
    ("array_slice",       "(ARRAY[l_orderkey, l_partkey])[1:2]"),
    ("trim_array",        "trim_array(ARRAY[l_orderkey, l_partkey], 1)"),
    ("array_upper",       "array_upper(ARRAY[l_orderkey, l_partkey], 1)"),
]))

# ----------------------------------------------------------------- 9.20
SPEC.append(("09-20_range", "9.20 Range/Multirange Functions and Operators",
 "least()/greatest() guard the constructor: a range whose lower bound exceeds\n"
 "-- its upper bound raises an error.", [
    ("daterange_make",  "daterange(least(l_shipdate, l_receiptdate), greatest(l_shipdate, l_receiptdate), '[]')"),
    ("contains_elem",   "daterange(least(l_shipdate, l_receiptdate), greatest(l_shipdate, l_receiptdate), '[]') @> DATE '1995-06-15'"),
    ("contains_range",  "daterange(least(l_shipdate, l_receiptdate), greatest(l_shipdate, l_receiptdate), '[]') @> daterange(DATE '1995-06-15', DATE '1995-06-16')"),
    ("contained_by",    "daterange(least(l_shipdate, l_receiptdate), greatest(l_shipdate, l_receiptdate), '[]') <@ daterange(DATE '1990-01-01', DATE '2000-01-01')"),
    ("overlaps",        "daterange(least(l_shipdate, l_receiptdate), greatest(l_shipdate, l_receiptdate), '[]') && daterange(DATE '1995-01-01', DATE '1995-12-31')"),
    ("strictly_left",   "daterange(least(l_shipdate, l_receiptdate), greatest(l_shipdate, l_receiptdate), '[]') << daterange(DATE '1999-01-01', DATE '2000-01-01')"),
    ("strictly_right",  "daterange(least(l_shipdate, l_receiptdate), greatest(l_shipdate, l_receiptdate), '[]') >> daterange(DATE '1990-01-01', DATE '1991-01-01')"),
    ("adjacent",        "daterange(least(l_shipdate, l_receiptdate), greatest(l_shipdate, l_receiptdate), '[]') -|- daterange(DATE '1999-01-01', DATE '2000-01-01')"),
    # Range union raises "result of range union would not be contiguous" when
    # the two ranges neither overlap nor touch, which a fixed literal range
    # cannot guarantee across every row. Unioning the row's range with itself
    # is always contiguous (it does construct the range twice).
    ("union",           "daterange(least(l_shipdate, l_receiptdate), greatest(l_shipdate, l_receiptdate), '[]') + daterange(least(l_shipdate, l_receiptdate), greatest(l_shipdate, l_receiptdate), '[]')"),
    ("intersect",       "daterange(least(l_shipdate, l_receiptdate), greatest(l_shipdate, l_receiptdate), '[]') * daterange(DATE '1990-01-01', DATE '2000-01-01')"),
    ("lower",           "lower(daterange(least(l_shipdate, l_receiptdate), greatest(l_shipdate, l_receiptdate), '[]'))"),
    ("upper",           "upper(daterange(least(l_shipdate, l_receiptdate), greatest(l_shipdate, l_receiptdate), '[]'))"),
    ("isempty",         "isempty(daterange(least(l_shipdate, l_receiptdate), greatest(l_shipdate, l_receiptdate), '[]'))"),
    ("multirange",      "datemultirange(daterange(least(l_shipdate, l_receiptdate), greatest(l_shipdate, l_receiptdate), '[]'))"),
]))

# ----------------------------------------------------------------- 9.21 (aggregates: whole-table shape)
SPEC.append(("09-21_aggregate", "9.21 Aggregate Functions",
 "Aggregates collapse the table to one row, so unlike the projection queries\n"
 "-- there is no per-row output to discard; the aggregate IS the operation here.", [
    ("count_star",      "RAW:SELECT count(*) FROM lineitem"),
    ("count_col",       "RAW:SELECT count(l_comment) FROM lineitem"),
    ("count_distinct",  "RAW:SELECT count(DISTINCT l_orderkey) FROM lineitem"),
    ("sum",             "RAW:SELECT sum(l_quantity) FROM lineitem"),
    ("sum_float8",      "RAW:SELECT sum(l_quantity::float8) FROM lineitem"),
    ("avg",             "RAW:SELECT avg(l_extendedprice) FROM lineitem"),
    ("min",             "RAW:SELECT min(l_shipdate) FROM lineitem"),
    ("max",             "RAW:SELECT max(l_shipdate) FROM lineitem"),
    ("stddev",          "RAW:SELECT stddev(l_discount) FROM lineitem"),
    ("stddev_pop",      "RAW:SELECT stddev_pop(l_discount) FROM lineitem"),
    ("variance",        "RAW:SELECT variance(l_tax) FROM lineitem"),
    ("var_pop",         "RAW:SELECT var_pop(l_tax) FROM lineitem"),
    ("bool_and",        "RAW:SELECT bool_and(l_quantity > 0) FROM lineitem"),
    ("bool_or",         "RAW:SELECT bool_or(l_quantity > 0) FROM lineitem"),
    ("bit_and",         "RAW:SELECT bit_and(l_linenumber) FROM lineitem"),
    ("bit_or",          "RAW:SELECT bit_or(l_linenumber) FROM lineitem"),
    ("corr",            "RAW:SELECT corr(l_quantity::float8, l_extendedprice::float8) FROM lineitem"),
    ("regr_slope",      "RAW:SELECT regr_slope(l_quantity::float8, l_extendedprice::float8) FROM lineitem"),
    ("percentile_cont", "RAW:SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY l_quantity) FROM lineitem"),
    ("percentile_disc", "RAW:SELECT percentile_disc(0.5) WITHIN GROUP (ORDER BY l_quantity) FROM lineitem"),
    ("mode",            "RAW:SELECT mode() WITHIN GROUP (ORDER BY l_returnflag) FROM lineitem"),
    ("group_by",        "RAW:SELECT l_returnflag, count(*) FROM lineitem GROUP BY l_returnflag"),
    # FILTER clause: aggregate only over rows matching a predicate.
    ("count_filter",    "RAW:SELECT count(*) FILTER (WHERE l_discount > 0.05) FROM lineitem"),
    ("sum_filter",      "RAW:SELECT sum(l_quantity) FILTER (WHERE l_returnflag = 'R') FROM lineitem"),
    # Collecting aggregates. Grouped by l_orderkey (1.5M groups of ~4 rows) so
    # each accumulated array/string/json stays small -> no single huge value.
    ("array_agg",       "RAW:SELECT array_agg(l_linenumber) FROM lineitem GROUP BY l_orderkey"),
    ("array_agg_orderby","RAW:SELECT array_agg(l_linenumber ORDER BY l_shipdate) FROM lineitem GROUP BY l_orderkey"),
    ("string_agg",      "RAW:SELECT string_agg(l_linestatus, ',') FROM lineitem GROUP BY l_orderkey"),
    ("json_agg",        "RAW:SELECT json_agg(l_linenumber) FROM lineitem GROUP BY l_orderkey"),
    ("jsonb_agg",       "RAW:SELECT jsonb_agg(l_linenumber) FROM lineitem GROUP BY l_orderkey"),
    # Ordered-set / hypothetical-set aggregates (WITHIN GROUP).
    ("rank_hypothetical",       "RAW:SELECT rank(30) WITHIN GROUP (ORDER BY l_quantity) FROM lineitem"),
    ("dense_rank_hypothetical", "RAW:SELECT dense_rank(30) WITHIN GROUP (ORDER BY l_quantity) FROM lineitem"),
    ("percent_rank_hypothetical","RAW:SELECT percent_rank(30) WITHIN GROUP (ORDER BY l_quantity) FROM lineitem"),
    ("cume_dist_hypothetical",  "RAW:SELECT cume_dist(30) WITHIN GROUP (ORDER BY l_quantity) FROM lineitem"),
    ("percentile_cont_array",   "RAW:SELECT percentile_cont(ARRAY[0.25,0.5,0.75,0.9]) WITHIN GROUP (ORDER BY l_quantity) FROM lineitem"),
]))

# ----------------------------------------------------------------- 9.22 (window)
SPEC.append(("09-22_window", "9.22 Window Functions",
 "All of these share the same window (ORDER BY l_shipdate), so the sort cost is\n"
 "-- common to every query and cancels out when they are compared with each\n"
 "-- other. row_number is the cheapest and doubles as this section's baseline.\n"
 "-- The window value is the projection, so it cannot be optimised away.\n"
 "--\n"
 "-- READ first_value / nth_value WITH CARE. They measure ~8x the rest (31s vs\n"
 "-- 4s at SF1), but that is NOT intrinsic function cost - it is TUPLESTORE\n"
 "-- SPILL. With no PARTITION BY the partition is all 6M rows, held in a\n"
 "-- WindowAgg tuplestore that overflows work_mem and spills to disk. The\n"
 "-- default frame is RANGE UNBOUNDED PRECEDING .. CURRENT ROW, and\n"
 "-- first_value / nth_value read the frame HEAD, so every row seeks a read\n"
 "-- pointer parked far behind the scan position - a disk seek per row.\n"
 "-- last_value reads the frame TAIL (at the current position, still buffered)\n"
 "-- and costs the same as row_number. Measured proof: raising work_mem to 4GB\n"
 "-- takes first_value 31.9s -> 4.0s, while switching RANGE->ROWS changes\n"
 "-- nothing, so frame MODE is not the cause. Core/12_memory_workmem has an\n"
 "-- explicit window_spill / window_nospill pair for this effect.\n"
 "-- Reading the frame head is also why their OUTPUT is one repeated value\n"
 "-- (verified: 1 distinct value over all 6M rows, vs 50 for last_value); the\n"
 "-- constancy itself is free - EXPLAIN ANALYZE still evaluates all 6M rows.", [
    ("row_number",   "row_number() OVER (ORDER BY l_shipdate)"),
    ("rank",         "rank() OVER (ORDER BY l_shipdate)"),
    ("dense_rank",   "dense_rank() OVER (ORDER BY l_shipdate)"),
    ("percent_rank", "percent_rank() OVER (ORDER BY l_shipdate)"),
    ("cume_dist",    "cume_dist() OVER (ORDER BY l_shipdate)"),
    ("ntile",        "ntile(10) OVER (ORDER BY l_shipdate)"),
    ("lag",          "lag(l_quantity) OVER (ORDER BY l_shipdate)"),
    ("lead",         "lead(l_quantity) OVER (ORDER BY l_shipdate)"),
    ("first_value",  "first_value(l_quantity) OVER (ORDER BY l_shipdate)"),
    ("last_value",   "last_value(l_quantity) OVER (ORDER BY l_shipdate)"),
    ("nth_value",    "nth_value(l_quantity, 2) OVER (ORDER BY l_shipdate)"),
    ("sum_over",     "sum(l_quantity) OVER (ORDER BY l_shipdate)"),
    ("avg_over",     "avg(l_quantity) OVER (ORDER BY l_shipdate)"),
    ("count_over",   "count(*) OVER (ORDER BY l_shipdate)"),
    ("partition_by", "row_number() OVER (PARTITION BY l_returnflag ORDER BY l_shipdate)"),
    # PARTITION BY granularity vs the frame-head spill above. Partition SIZE, not
    # partition COUNT, decides whether the per-partition tuplestore fits work_mem:
    # 3 partitions of ~2M rows still spill and stay slow, while 200k/1.5M tiny
    # partitions fit and collapse first_value back to the row_number baseline.
    # Measured at SF1: 31.1s (none) / 32.4s (3) / 5.3s (200k) / 4.3s (1.5M).
    ("first_value_part_3",     "first_value(l_quantity) OVER (PARTITION BY l_returnflag ORDER BY l_shipdate)"),
    ("first_value_part_200k",  "first_value(l_quantity) OVER (PARTITION BY l_partkey ORDER BY l_shipdate)"),
    ("first_value_part_1500k", "first_value(l_quantity) OVER (PARTITION BY l_orderkey ORDER BY l_shipdate)"),
    # Same tiny partitions for a function that never seeks the frame head, so the
    # difference from first_value_part_1500k is the frame-head access alone.
    ("row_number_part_1500k",  "row_number() OVER (PARTITION BY l_orderkey ORDER BY l_shipdate)"),
    ("last_value_part_1500k",  "last_value(l_quantity) OVER (PARTITION BY l_orderkey ORDER BY l_shipdate)"),
    # Frame clauses: same running sum, different frame -> different buffering.
    ("frame_rows_running",   "sum(l_quantity) OVER (ORDER BY l_shipdate ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)"),
    ("frame_rows_centered",  "sum(l_quantity) OVER (ORDER BY l_shipdate ROWS BETWEEN 5 PRECEDING AND 5 FOLLOWING)"),
    ("frame_rows_following", "sum(l_quantity) OVER (ORDER BY l_shipdate ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)"),
    ("frame_range_running",  "sum(l_quantity) OVER (ORDER BY l_shipdate RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)"),
    ("frame_groups",         "sum(l_quantity) OVER (ORDER BY l_shipdate GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING)"),
    ("frame_exclude_current","sum(l_quantity) OVER (ORDER BY l_shipdate ROWS BETWEEN 5 PRECEDING AND 5 FOLLOWING EXCLUDE CURRENT ROW)"),
    ("frame_exclude_ties",   "sum(l_quantity) OVER (ORDER BY l_shipdate RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW EXCLUDE TIES)"),
]))

# ----------------------------------------------------------------- 9.24 (subquery: WHERE shape)
SPEC.append(("09-24_subquery", "9.24 Subquery Expressions",
 "These take the WHERE-clause form because that is how subquery expressions are\n"
 "-- actually used; the planner turns most of them into semi/anti-joins.", [
    ("exists",         "RAW:SELECT 1 FROM lineitem l WHERE EXISTS (SELECT 1 FROM orders o WHERE o.o_orderkey = l.l_orderkey)"),
    ("not_exists",     "RAW:SELECT 1 FROM lineitem l WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.o_orderkey = l.l_orderkey)"),
    ("in_subquery",    "RAW:SELECT 1 FROM lineitem l WHERE l.l_partkey IN (SELECT p_partkey FROM part WHERE p_size < 5)"),
    ("not_in_subquery","RAW:SELECT 1 FROM lineitem l WHERE l.l_partkey NOT IN (SELECT p_partkey FROM part WHERE p_size < 5)"),
    ("any_subquery",   "RAW:SELECT 1 FROM lineitem l WHERE l.l_partkey = ANY (SELECT p_partkey FROM part WHERE p_size < 5)"),
    ("all_subquery",   "RAW:SELECT 1 FROM lineitem l WHERE l.l_partkey <> ALL (SELECT p_partkey FROM part WHERE p_size < 5)",
     "WARNING - PATHOLOGICAL: ~45 MIN PER RUN (measured: ~80 min single-threaded,\n"
     "-- ~45 min with 2 parallel workers). RUNS=3 on this one file takes ~2.2 hours.\n"
     "-- It does complete - it is CPU-bound and finite, not hung - but it will stall\n"
     "-- any sweep it is part of. Run it deliberately with RUNS=1, not in a batch.\n"
     "--\n"
     "-- Why: compare its plan with not_in_subquery.sql, which is semantically\n"
     "-- identical but runs in ~2s. The planner turns NOT IN into a 'hashed SubPlan'\n"
     "-- (one hash build, O(1) probes), whereas <> ALL gets a 'Materialize' SubPlan\n"
     "-- re-scanned for every outer row: 6M rows x 16209 inner rows. Measured cost is\n"
     "-- ~803 us per outer row, and it scales with the INNER SET SIZE (a 1-row inner\n"
     "-- set costs only ~12 us/row, i.e. ~72s total - that is the SubPlan invocation\n"
     "-- floor). This NOT IN vs <> ALL pair is the most striking energy finding in\n"
     "-- the set: identical semantics, ~1000x the energy."),
    ("scalar_subquery","RAW:SELECT (SELECT max(p_size) FROM part) FROM lineitem"),
]))

# ----------------------------------------------------------------- 9.25
SPEC.append(("09-25_row_comparison", "9.25 Row and Array Comparisons", None, [
    ("row_eq",           "(l_returnflag, l_linestatus) = ('A', 'F')"),
    ("row_ne",           "(l_returnflag, l_linestatus) <> ('A', 'F')"),
    ("row_lt",           "(l_orderkey, l_linenumber) < (100, 2)"),
    ("row_in",           "(l_returnflag, l_linestatus) IN (('A', 'F'), ('R', 'F'))"),
    ("row_is_distinct",  "(l_returnflag, l_linestatus) IS DISTINCT FROM ('A', 'F')"),
    ("in_list",          "l_linenumber IN (1, 2, 3)"),
    ("not_in_list",      "l_linenumber NOT IN (1, 2, 3)"),
    ("any_array",        "l_linenumber = ANY (ARRAY[1, 2, 3])"),
    ("all_array",        "l_linenumber <> ALL (ARRAY[1, 2, 3])"),
]))

# ----------------------------------------------------------------- 9.26 (set returning: expands rows)
SPEC.append(("09-26_set_returning", "9.26 Set Returning Functions",
 "Unlike every other section these EXPAND the row count (each input row yields\n"
 "-- many), so they are comparable with each other but not with the projection\n"
 "-- queries elsewhere.", [
    ("unnest",                 "unnest(string_to_array(l_comment, ' '))"),
    ("string_to_table",        "string_to_table(l_comment, ' ')"),
    ("regexp_split_to_table",  "regexp_split_to_table(l_comment, ' ')"),
    ("generate_series_int",    "generate_series(1, l_linenumber)"),
    ("generate_subscripts",    "generate_subscripts(ARRAY[l_orderkey, l_partkey], 1)"),
    ("jsonb_array_elements",   "jsonb_array_elements(jsonb_build_array(l_orderkey, l_partkey))"),
    ("jsonb_object_keys",      "jsonb_object_keys(jsonb_build_object('k', l_orderkey, 'c', l_comment))"),
]))

# ----------------------------------------------------------------- 9.27
SPEC.append(("09-27_system_info", "9.27 System Information Functions and Operators",
 "Functions marked stable (version(), current_database(), ...) are evaluated\n"
 "-- once for the whole query rather than per row, so they measure close to the\n"
 "-- baseline by design; pg_column_size and pg_typeof are the per-row ones.", [
    ("pg_typeof",        "pg_typeof(l_quantity)"),
    ("pg_column_size",   "pg_column_size(l_comment)"),
    ("pg_column_size_int","pg_column_size(l_orderkey)"),
    ("current_database", "current_database()"),
    ("current_user",     "current_user"),
    ("version",          "version()"),
    ("current_setting",  "current_setting('server_version')"),
    ("pg_backend_pid",   "pg_backend_pid()"),
]))


def render(section_title, note, name, body, opnote=None):
    """Build the text of one .sql file."""
    lines = ["-- %s" % section_title, "-- Operation: %s" % name]
    if note:
        lines.append("-- " + note)
    if opnote:
        lines.append("-- " + opnote)
    lines.append("-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and")
    lines.append("-- evaluates the target list, but discards rows server-side: no aggregate")
    lines.append("-- is added and no rows are transferred to the client.")
    if body.startswith("RAW:"):
        stmt = body[4:]
    else:
        stmt = "SELECT %s\nFROM lineitem" % body
    lines.append(HEADER)
    lines.append(stmt + ";")
    return "\n".join(lines) + "\n"


def main():
    for root in (OUT_ROOT, LONG_ROOT):
        if os.path.isdir(root):
            shutil.rmtree(root)

    total = 0
    long_total = 0
    for section_dir, title, note, ops in SPEC:
        for op in ops:
            name, body = op[0], op[1]
            opnote = op[2] if len(op) > 2 else None
            # Route pathologically slow operations to the separate queries/slow
            # tree; everything else goes to Functions.
            root = LONG_ROOT if (section_dir, name) in LONG_RUNNING else OUT_ROOT
            d = os.path.join(root, section_dir)
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, name + ".sql"), "w") as fh:
                fh.write(render(title, note, name, body, opnote))
            if root is LONG_ROOT:
                long_total += 1
            else:
                total += 1
        print("%-26s %3d queries" % (section_dir, len(ops)))
    print("-" * 40)
    print("%-26s %3d queries -> Functions" % ("TOTAL", total))
    print("%-26s %3d queries -> queries/slow" % ("long-running", long_total))


if __name__ == "__main__":
    main()
