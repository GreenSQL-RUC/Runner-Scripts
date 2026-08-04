-- JIT: expression compilation on vs off
-- Operation: jit_optimize
-- Identical arithmetic-heavy scan; only the JIT settings differ. 'on' forces
-- compilation (thresholds set to 0); progressively adds inlining then LLVM
-- optimization. RAPL captures both the one-time compile energy and the
-- changed per-row cost. On a scan-bound query the net effect is small -
-- which is itself the finding. The plan's 'JIT:' block (function count and
-- which optimizations ran) is printed in ./plans, so each file's settings
-- can be confirmed to have taken effect.
-- Compile + inline + full LLVM optimization (most compile energy).
-- Read-only: EXPLAIN ANALYZE executes the plan and evaluates the target
-- list but discards rows server-side; every SET below is session-local to
-- this psql invocation and vanishes when it exits.
SET jit = on;
SET jit_above_cost = 0;
SET jit_inline_above_cost = 0;
SET jit_optimize_above_cost = 0;
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT sum(sqrt(l_extendedprice::float8) + ln(l_quantity::float8 + 1) + sin(l_discount::float8) + power(l_tax::float8 + 1, 3)) FROM lineitem;
