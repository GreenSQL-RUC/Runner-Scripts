import csv
from collections import defaultdict
from contextlib import redirect_stdout

with open('estat_nama_10_a64_p5.csv', newline='') as f:
    r = csv.reader(f)
    header = next(r)
    rows = list(r)

with open('estat_out.txt', 'w') as estat_out:
    with redirect_stdout(estat_out):
        print(f"Total rows: {len(rows)}")
        print(f"Columns: {header}")

# Cardinality check: how many distinct values does each column have
        for i, col in enumerate(header):
            distinct = len(set(row[i] for row in rows))
            ratio = distinct/len(rows)
# a low ration indicated heavy repitition (aka a storng normalization candidate), while high ratios close to 100% indicate
# the column belongs to the table itself rather than a dimension.
            print(f"{col}: {distinct} distinct values" f"({ratio:.2%} of rows)")

# checking if a candidate key maps consistently to other columns
# point to diff descriptions (a data-quality issue we need to design around)

        dimension_candidates = [
            'freq', 
            'unit', 
            'nace_r2',
            'asset10',
            'na_item',
            'geo\\TIME_PERIOD'
        ]
        print (f"\nDimension cardinalities")

        for col in dimension_candidates:
            idx = header.index(col)
            distinct = len(set(row[idx] for row in rows))
            print(f"{col}: {distinct}")

#max field lengths
        maxlen = [max(len(row[i]) for row in rows) for i in range(len(header))]
        print(dict(zip(header, maxlen)))