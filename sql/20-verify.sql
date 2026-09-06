-- Completeness verification for a loaded state.
--
-- A load exiting 0 does not mean it loaded everything. The generated scripts
-- iterate over files with globs, and the hardening that stops a missing file
-- from aborting the whole run (shopt -s nullglob) necessarily turns that missing
-- file into a silent skip instead. County-level layers -- faces, featnames,
-- edges, addr -- are fetched one file per county, so a large state can lose a
-- dozen counties and still look entirely healthy from the outside.
--
-- So completeness is asserted against the data, not the exit code: every layer
-- the loader was configured to load must exist, hold rows, and cover every
-- county the nation load says the state has.
CREATE OR REPLACE FUNCTION api.verify_state(state text, deep boolean DEFAULT false)
RETURNS TABLE (
	layer text,
	check_name text,
	ok boolean,
	detail text
)
LANGUAGE plpgsql
STABLE
SET search_path = tiger, public
AS $fn$
DECLARE
	abbrev text := lower(verify_state.state);
	fips text;
	rec record;
	qualified text;
	edges_table text := lower(verify_state.state) || '_edges';
	n bigint;
	expected text[];
	actual text[];
	missing text[];
BEGIN
	SELECT s.statefp INTO fips
	FROM tiger_data.state_all s WHERE s.stusps = upper(abbrev);

	IF fips IS NULL THEN
		RETURN QUERY SELECT
			NULL::text, 'state_known'::text, false,
			format('%s is not in tiger_data.state_all; run the nation load first',
				upper(abbrev))::text;
		RETURN;
	END IF;

	SELECT array_agg(c.countyfp ORDER BY c.countyfp) INTO expected
	FROM tiger_data.county_all c WHERE c.statefp = fips;

	FOR rec IN
		SELECT l.lookup_name
		FROM tiger.loader_lookuptables l
		WHERE l.load AND NOT l.level_nation
		ORDER BY l.process_order, l.lookup_name
	LOOP
		qualified := format('tiger_data.%I', abbrev || '_' || rec.lookup_name);

		IF to_regclass(qualified) IS NULL THEN
			RETURN QUERY SELECT
				rec.lookup_name::text, 'table_exists'::text, false,
				format('%s is missing; the layer was skipped entirely', qualified)::text;
			CONTINUE;
		END IF;

		RETURN QUERY SELECT rec.lookup_name::text, 'table_exists'::text, true, NULL::text;

		EXECUTE format('SELECT count(*) FROM %s', qualified) INTO n;
		RETURN QUERY SELECT
			rec.lookup_name::text, 'not_empty'::text, n > 0,
			format('%s rows', n)::text;

		actual := NULL;

		IF EXISTS (
			SELECT 1 FROM pg_attribute a
			WHERE a.attrelid = qualified::regclass
			  AND a.attname = 'countyfp' AND a.attnum > 0 AND NOT a.attisdropped
		) THEN
			EXECUTE format(
				'SELECT array_agg(DISTINCT countyfp ORDER BY countyfp) FROM %s', qualified)
			INTO actual;
		ELSIF deep
			AND to_regclass(format('tiger_data.%I', edges_table)) IS NOT NULL
			AND EXISTS (
				SELECT 1 FROM pg_attribute a
				WHERE a.attrelid = qualified::regclass
				  AND a.attname = 'tlid' AND a.attnum > 0 AND NOT a.attisdropped
			)
		THEN
			-- featnames and addr carry no countyfp. They do carry tlid, which
			-- edges maps to a county, so coverage is recoverable -- at the cost
			-- of a join across two of the largest tables in the schema.
			EXECUTE format(
				'SELECT array_agg(DISTINCT e.countyfp ORDER BY e.countyfp)
				 FROM %s f JOIN tiger_data.%I e ON e.tlid = f.tlid',
				qualified, edges_table)
			INTO actual;
		ELSE
			RETURN QUERY SELECT
				rec.lookup_name::text, 'county_coverage'::text, NULL::boolean,
				'not checked: no countyfp column (pass deep => true to join via edges.tlid)'::text;
			CONTINUE;
		END IF;

		SELECT array_agg(c ORDER BY c) INTO missing
		FROM (
			SELECT unnest(expected)
			EXCEPT
			SELECT unnest(coalesce(actual, '{}'::text[]))
		) AS q(c);

		RETURN QUERY SELECT
			rec.lookup_name::text, 'county_coverage'::text,
			coalesce(cardinality(missing), 0) = 0,
			format('%s of %s counties%s',
				coalesce(cardinality(actual), 0),
				coalesce(cardinality(expected), 0),
				CASE WHEN coalesce(cardinality(missing), 0) > 0
					THEN '; missing ' || array_to_string(missing, ',')
					ELSE '' END)::text;
	END LOOP;
END;
$fn$;

COMMENT ON FUNCTION api.verify_state(text, boolean) IS
	'Per-layer completeness checks for a loaded state. ok IS NULL means not checked.';

-- A state is complete when nothing failed. Checks that could not run report NULL
-- and are deliberately not counted as failures -- they are unknowns, not passes,
-- and api.verify_state shows which.
CREATE OR REPLACE FUNCTION api.state_is_complete(state text, deep boolean DEFAULT false)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = tiger, public
AS $$
	SELECT NOT EXISTS (
		SELECT 1 FROM api.verify_state(state_is_complete.state, state_is_complete.deep) AS v
		WHERE v.ok IS FALSE
	);
$$;

COMMENT ON FUNCTION api.state_is_complete(text, boolean) IS
	'True when no completeness check failed for the state.';
