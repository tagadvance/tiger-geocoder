-- Is the latency bimodal, and which addresses are slow?
SELECT count(*)                                              AS calls,
       round(percentile_cont(0.5)  WITHIN GROUP (ORDER BY ms)::numeric, 1) AS p50_ms,
       round(percentile_cont(0.9)  WITHIN GROUP (ORDER BY ms)::numeric, 1) AS p90_ms,
       round(percentile_cont(0.99) WITHIN GROUP (ORDER BY ms)::numeric, 1) AS p99_ms,
       round(max(ms)::numeric, 1)                             AS max_ms,
       round(avg(ms) FILTER (WHERE hits = 0)::numeric, 1)     AS avg_ms_when_no_match,
       count(*) FILTER (WHERE hits = 0)                       AS no_match
FROM bench.timings;

-- Histogram: a second hump well above the median is the slow path.
SELECT width_bucket(ms, 0, 400, 20) * 20 AS up_to_ms, count(*) AS calls,
       repeat('#', (count(*) * 60 / max(count(*)) OVER ())::integer) AS bar
FROM bench.timings GROUP BY 1 ORDER BY 1;

-- The slowest addresses: what do they have in common?
SELECT round(ms::numeric) AS ms, hits, address
FROM bench.timings ORDER BY ms DESC LIMIT 15;

-- And the same street twice: is slowness a property of the address or the run?
SELECT address, count(*) AS n, round(min(ms)::numeric) AS min_ms, round(max(ms)::numeric) AS max_ms
FROM bench.timings GROUP BY address HAVING count(*) > 2 ORDER BY max(ms) - min(ms) DESC LIMIT 8;
