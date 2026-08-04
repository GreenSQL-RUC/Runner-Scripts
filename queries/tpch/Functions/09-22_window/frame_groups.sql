-- 9.22 Window Functions
-- Operation: frame_groups
-- All of these share the same window (ORDER BY l_shipdate), so the sort cost is
-- common to every query and cancels out when they are compared with each
-- other. row_number is the cheapest and doubles as this section's baseline.
-- The window value is the projection, so it cannot be optimised away.
--
-- READ first_value / nth_value WITH CARE. They measure ~8x the rest (31s vs
-- 4s at SF1), but that is NOT intrinsic function cost - it is TUPLESTORE
-- SPILL. With no PARTITION BY the partition is all 6M rows, held in a
-- WindowAgg tuplestore that overflows work_mem and spills to disk. The
-- default frame is RANGE UNBOUNDED PRECEDING .. CURRENT ROW, and
-- first_value / nth_value read the frame HEAD, so every row seeks a read
-- pointer parked far behind the scan position - a disk seek per row.
-- last_value reads the frame TAIL (at the current position, still buffered)
-- and costs the same as row_number. Measured proof: raising work_mem to 4GB
-- takes first_value 31.9s -> 4.0s, while switching RANGE->ROWS changes
-- nothing, so frame MODE is not the cause. Core/12_memory_workmem has an
-- explicit window_spill / window_nospill pair for this effect.
-- Reading the frame head is also why their OUTPUT is one repeated value
-- (verified: 1 distinct value over all 6M rows, vs 50 for last_value); the
-- constancy itself is free - EXPLAIN ANALYZE still evaluates all 6M rows.
-- Full lineitem scan (no LIMIT). EXPLAIN ANALYZE executes the plan and
-- evaluates the target list, but discards rows server-side: no aggregate
-- is added and no rows are transferred to the client.
EXPLAIN (ANALYZE, TIMING OFF, COSTS ON, SUMMARY ON, BUFFERS)
SELECT sum(l_quantity) OVER (ORDER BY l_shipdate GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING)
FROM lineitem;
