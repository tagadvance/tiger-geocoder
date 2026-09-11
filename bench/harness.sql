-- Applied by run.sh on every run; the one-time sample lives in setup.sql.
-- pgbench aborts a client on any SQL error, so one address the geocoder
-- chokes on would end the run. Catch it, record it, keep going. The subtransaction
-- this costs is small next to a geocode and is the same for every call, so it
-- shifts the numbers uniformly rather than distorting the curve.
DROP TABLE IF EXISTS bench.failures;
CREATE UNLOGGED TABLE bench.failures (
	address text,
	error text,
	seen_at timestamptz DEFAULT now()
);

-- Per-address latency, so the addresses that take the slow path identify
-- themselves. One row per call; ~30k rows per QUICK run, trivial.
-- UNLOGGED: a transaction that writes only to unlogged tables has no WAL to
-- flush at commit, so the per-call INSERT stops costing an fsync. With the
-- serve profile's synchronous_commit=on, a logged table here made every
-- benchmark call a disk sync -- and a checkpoint landing mid-run stalled a few
-- of them for seconds, which then looked like slow addresses.
DROP TABLE IF EXISTS bench.timings;
CREATE UNLOGGED TABLE bench.timings (
	address text,
	hits integer,
	ms double precision
);

CREATE OR REPLACE FUNCTION bench.geocode_safe(address text)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
	hits integer;
	started timestamptz := clock_timestamp();
BEGIN
	SELECT count(*) INTO hits FROM api.geocode(address, 1);
	INSERT INTO bench.timings VALUES
		(address, hits, extract(epoch FROM clock_timestamp() - started) * 1000);
	RETURN hits;
EXCEPTION WHEN OTHERS THEN
	INSERT INTO bench.failures (address, error) VALUES (address, SQLERRM);
	RETURN -1;
END
$$;
