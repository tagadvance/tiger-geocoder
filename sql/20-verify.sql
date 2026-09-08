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
-- county the nation load says the state has -- less the files the Census does
-- not publish, which the loader records here as it meets them. American Samoa
-- has no address ranges at all; without this ledger the verifier would demand
-- five county files that do not exist and fail the state forever.
CREATE TABLE IF NOT EXISTS api.not_published (
	state text NOT NULL,
	name text NOT NULL,
	layer text NOT NULL,
	countyfp text,
	recorded_at timestamptz NOT NULL DEFAULT now(),
	PRIMARY KEY (state, name)
);

COMMENT ON TABLE api.not_published IS
	'Census files the loader was told do not exist (404, or 550 over ftp). countyfp is NULL for a state-level file.';

-- Replaces the state's list, so a reload starts clean; an empty list clears it.
-- Names are the zip basenames the loader fetches: tl_2025_60010_addr.zip is
-- state 60, county 010, layer addr; tl_2025_60_place.zip has no county.
CREATE OR REPLACE FUNCTION api.record_not_published(state text, names text[])
RETURNS integer
LANGUAGE plpgsql
SET search_path = tiger, public
AS $fn$
DECLARE
	upper_state text := upper(record_not_published.state);
	recorded integer;
BEGIN
	DELETE FROM api.not_published n WHERE n.state = upper_state;
	INSERT INTO api.not_published (state, name, layer, countyfp)
	SELECT upper_state, q.name, q.m[3], q.m[2]
	FROM (
		SELECT u.name,
		       regexp_match(u.name, '^tl_[0-9]{4}_([0-9]{2})([0-9]{3})?_([a-z0-9]+)\.zip$') AS m
		FROM unnest(names) AS u(name)
	) AS q
	WHERE q.m IS NOT NULL;
	GET DIAGNOSTICS recorded = ROW_COUNT;
	RETURN recorded;
END;
$fn$;

COMMENT ON FUNCTION api.record_not_published(text, text[]) IS
	'Record the files the Census does not publish for a state; the verifier stops expecting them.';

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
	unpublished text[];
	layer_unpublished boolean;
	owed text[];
	actual text[];
	missing text[];
	has_tlid boolean;
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

		-- What the Census does not publish for this layer is not owed.
		SELECT array_agg(np.countyfp ORDER BY np.countyfp) INTO unpublished
		FROM api.not_published np
		WHERE np.state = upper(abbrev) AND np.layer = rec.lookup_name
		  AND np.countyfp IS NOT NULL;
		layer_unpublished := EXISTS (
			SELECT 1 FROM api.not_published np
			WHERE np.state = upper(abbrev) AND np.layer = rec.lookup_name
			  AND np.countyfp IS NULL);
		SELECT array_agg(c ORDER BY c) INTO owed
		FROM unnest(expected) AS c
		WHERE NOT (c = ANY (coalesce(unpublished, '{}'::text[])));

		EXECUTE format('SELECT count(*) FROM %s', qualified) INTO n;
		IF n = 0 AND (layer_unpublished
			OR (coalesce(cardinality(unpublished), 0) > 0
				AND coalesce(cardinality(owed), 0) = 0))
		THEN
			RETURN QUERY SELECT
				rec.lookup_name::text, 'not_empty'::text, true,
				'0 rows; the Census publishes no file for this layer here'::text;
		ELSE
			RETURN QUERY SELECT
				rec.lookup_name::text, 'not_empty'::text, n > 0,
				format('%s rows', n)::text;
		END IF;

		actual := NULL;

		-- tabblock20 is the 2020 Census block layer; its GEOID20 is frozen to 2020
		-- geography and so is its countyfp. county_all is current. They agree
		-- everywhere a county has not been redrawn since 2020 -- and disagree
		-- entirely in Connecticut, which replaced eight counties with nine
		-- planning regions in 2022: the layer holds 001-015, county_all holds
		-- 110-190, and no county-coverage check against current codes can pass.
		-- Comparing against the 2020 county list would be exact, but nothing
		-- here holds one, and the block id is an optional attribute the geocoder
		-- does not match on. So it is not checked, and says so; not_empty above
		-- still guards against the layer being skipped.
		IF rec.lookup_name = 'tabblock20' THEN
			RETURN QUERY SELECT
				rec.lookup_name::text, 'county_coverage'::text, NULL::boolean,
				'not checked: 2020 Census geography; county codes predate boundary changes since'::text;
			CONTINUE;
		END IF;

		has_tlid := EXISTS (
			SELECT 1 FROM pg_attribute a
			WHERE a.attrelid = qualified::regclass
			  AND a.attname = 'tlid' AND a.attnum > 0 AND NOT a.attisdropped);

		IF EXISTS (
			SELECT 1 FROM pg_attribute a
			WHERE a.attrelid = qualified::regclass
			  AND a.attname = 'countyfp' AND a.attnum > 0 AND NOT a.attisdropped
		) THEN
			EXECUTE format(
				'SELECT array_agg(DISTINCT countyfp ORDER BY countyfp) FROM %s', qualified)
			INTO actual;
		ELSIF NOT has_tlid THEN
			-- place: no countyfp, no tlid. Nothing to join through, in any mode.
			RETURN QUERY SELECT
				rec.lookup_name::text, 'county_coverage'::text, NULL::boolean,
				'not checked: this layer has no county dimension'::text;
			CONTINUE;
		ELSIF NOT deep THEN
			RETURN QUERY SELECT
				rec.lookup_name::text, 'county_coverage'::text, NULL::boolean,
				'not checked: no countyfp column (pass deep => true to join via edges.tlid)'::text;
			CONTINUE;
		ELSIF to_regclass(format('tiger_data.%I', edges_table)) IS NULL THEN
			RETURN QUERY SELECT
				rec.lookup_name::text, 'county_coverage'::text, NULL::boolean,
				format('not checked: tiger_data.%s is missing, so tlid cannot be mapped to a county',
					edges_table)::text;
			CONTINUE;
		ELSE
			-- featnames and addr carry no countyfp. They do carry tlid, which
			-- edges maps to a county, so coverage is recoverable -- at the cost
			-- of a join across two of the largest tables in the schema.
			EXECUTE format(
				'SELECT array_agg(DISTINCT e.countyfp ORDER BY e.countyfp)
				 FROM %s f JOIN tiger_data.%I e ON e.tlid = f.tlid',
				qualified, edges_table)
			INTO actual;
		END IF;

		SELECT array_agg(c ORDER BY c) INTO missing
		FROM (
			SELECT unnest(coalesce(owed, '{}'::text[]))
			EXCEPT
			SELECT unnest(coalesce(actual, '{}'::text[]))
		) AS q(c);

		-- "N of M" is the overlap, not the layer's own count: a layer holding
		-- eight counties none of which are the nine owed is 0 of 9, not 8 of 9.
		RETURN QUERY SELECT
			rec.lookup_name::text, 'county_coverage'::text,
			coalesce(cardinality(missing), 0) = 0,
			format('%s of %s counties%s%s',
				coalesce(cardinality(owed), 0) - coalesce(cardinality(missing), 0),
				coalesce(cardinality(owed), 0),
				CASE WHEN coalesce(cardinality(missing), 0) > 0
					THEN '; missing ' || array_to_string(missing, ',')
					ELSE '' END,
				CASE WHEN coalesce(cardinality(unpublished), 0) > 0
					THEN format('; %s not published upstream', cardinality(unpublished))
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
