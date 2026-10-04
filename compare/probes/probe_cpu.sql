-- compare probe: pure CPU. One process, floating-point math over a generated
-- series; no table access and a cache-resident working set.
SELECT sum(sqrt(g::float8) * ln(g::float8 + 1)) FROM generate_series(1, 6000000) g;
