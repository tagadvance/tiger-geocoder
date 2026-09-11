-- Where does geocode() spend its time, planning or executing, and in which
-- nested statement? Run after a benchmark with pg_stat_statements.track=all and
-- track_planning=on. Times in ms per call so they can be summed against the
-- per-geocode wall figure from run.sh.
SELECT
	calls,
	plans,
	round((total_plan_time / nullif(plans, 0))::numeric, 2)         AS plan_ms_per_call,
	round((total_exec_time / nullif(calls, 0))::numeric, 2)         AS exec_ms_per_call,
	round((100 * total_plan_time / nullif(total_plan_time + total_exec_time, 0))::numeric) AS plan_pct,
	left(regexp_replace(query, '\s+', ' ', 'g'), 100)    AS query
FROM pg_stat_statements
WHERE query NOT ILIKE '%pg_stat_statements%'
ORDER BY total_plan_time + total_exec_time DESC
LIMIT 12;

-- And the totals: how many ms of planning vs execution happen per top-level geocode.
WITH top AS (
	SELECT calls FROM pg_stat_statements WHERE query LIKE '%bench.geocode_safe%' ORDER BY calls DESC LIMIT 1
)
SELECT
	top.calls                                                AS geocodes,
	round((sum(s.total_plan_time) / top.calls)::numeric, 1)             AS plan_ms_per_geocode,
	round((sum(s.total_exec_time) / top.calls)::numeric, 1)             AS exec_ms_per_geocode_nested_double_counts
FROM pg_stat_statements s, top
WHERE s.query NOT ILIKE '%pg_stat_statements%'
GROUP BY top.calls;
