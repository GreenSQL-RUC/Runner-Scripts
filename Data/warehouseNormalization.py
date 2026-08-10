import csv
from collections import defaultdict

with open('export.csv', newline='') as f:
    r = csv.reader(f)
    header = next(r)
    rows = list(r)
print(f"Total rows: {len(rows)}")
print(f"Columns: {header}")

# Cardinality check: how many distinct values does each column have
for i, col in enumerate(header):
    distinct = len(set(row[i] for row in rows))
    ratio = distinct/len(rows)
# a low ration indicated heavy repitition (aka a storng normalization candidate), while high ratios close to 100% indicate
# the column belongs to the table itself rather than a dimension.
print("{col}: {distinct} distinct values ({ratio:.2%} of rows)")

# checking if a candidate key maps consistently to other columns
# point to diff descriptions (a data-quality issue we need to design around)

code_to_desc = defaultdict(set)
for row in rows:
    item_code_idx, desc_idx, type_idx = header.index('ITEM CODE'), header.index('ITEM DESCRIPTION'), header.index('ITEM TYPE')
    code_to_desc[row[item_code_idx]].add((row[desc_idx], row[type_idx]))

inconsistent = {k: v for k, v in code_to_desc.items() if len(v) > 1}
print(f"Item codes with inconsistent desc/type: {len(inconsistent)}")

#max field lengths
maxlen = [max(len(row[i]) for row in rows) for i in range(len(header))]
print(dict(zip(header, maxlen)))