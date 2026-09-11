-- A stable, flat contract over the tiger geocoder.
--
-- Callers bind to api.* rather than to tiger.geocode() directly, for three
-- reasons: the tiger signatures return composite types (norm_addy) that most
-- clients handle badly, they have moved between PostGIS releases, and pinning
-- search_path on these functions means a caller cannot break geocoding simply
-- by having a different search_path of its own.
--
-- Coordinates are returned as WGS84 (EPSG:4326). TIGER itself is NAD83
-- (EPSG:4269); the two agree to within about a metre, but the transform is done
-- explicitly so the contract states one datum rather than implying two.
CREATE SCHEMA IF NOT EXISTS api;

COMMENT ON SCHEMA api IS
	'Stable contract over the tiger geocoder. Bind here, not to tiger internals.';

-- Internal. Both geocode entry points build a norm_addy and come through here,
-- so the flattening lives once.
CREATE OR REPLACE FUNCTION api.geocode_normalized(
	addy tiger.norm_addy,
	max_results integer
)
RETURNS TABLE (
	rating integer,
	longitude double precision,
	latitude double precision,
	street_number text,
	street text,
	street_type text,
	city text,
	state text,
	zip text,
	formatted text
)
LANGUAGE sql
STABLE
PARALLEL SAFE
SET search_path = tiger, public
AS $$
	SELECT
		g.rating,
		ST_X(ST_Transform(g.geomout, 4326))::double precision,
		ST_Y(ST_Transform(g.geomout, 4326))::double precision,
		COALESCE((g.addy).address_alphanumeric, (g.addy).address::text),
		(g.addy).streetname::text,
		(g.addy).streettypeabbrev::text,
		(g.addy).location::text,
		(g.addy).stateabbrev::text,
		(g.addy).zip::text,
		pprint_addy(g.addy)
	FROM geocode(geocode_normalized.addy, geocode_normalized.max_results) AS g
	ORDER BY g.rating;
$$;

COMMENT ON FUNCTION api.geocode_normalized(tiger.norm_addy, integer) IS
	'Internal. Bind to api.geocode or api.geocode_parts instead.';

CREATE OR REPLACE FUNCTION api.geocode(
	address text,
	max_results integer DEFAULT 1
)
RETURNS TABLE (
	rating integer,
	longitude double precision,
	latitude double precision,
	street_number text,
	street text,
	street_type text,
	city text,
	state text,
	zip text,
	formatted text
)
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SET search_path = tiger, public
AS $$
DECLARE
	addy tiger.norm_addy := normalize_address(address);
BEGIN
	-- The parser takes any trailing two-letter token for a state: "1701 21st
	-- Rd NE, 66871" becomes Nebraska and "998 2500 N Shelby Co, 62550" becomes
	-- Colorado, and geocode_address then trusts that state over the zip and
	-- returns a confidently rated match from the wrong one. The zip is the
	-- more reliable of the two, so where they disagree it wins. The ORDER BY
	-- keeps the parsed state when the zip legitimately spans two states; an
	-- unknown zip leaves the parse untouched.
	addy.stateabbrev := COALESCE((
		SELECT z.stusps
		FROM zip_state AS z
		WHERE z.zip = addy.zip
		ORDER BY z.stusps = addy.stateabbrev DESC, z.stusps
		LIMIT 1
	), addy.stateabbrev);

	RETURN QUERY SELECT * FROM api.geocode_normalized(addy, max_results);
END;
$$;

COMMENT ON FUNCTION api.geocode(text, integer) IS
	'Geocode a free-form US address. Lower rating is a better match; 0 is exact.';

-- For callers that already hold the address as components. On input with no
-- city ("600 N Sheridan St, 61832") the parser misassigns the trailing tokens
-- -- street "N", city "Sheridan St" -- on about a quarter of inputs; this
-- bypasses it. Not an overload of api.geocode: with (text, integer) and
-- (text, text, ...) both present, a call whose second argument is an untyped
-- literal or driver parameter would resolve silently to this one.
--
-- The input names differ from the output columns because RETURNS TABLE columns
-- are parameters too, and a name cannot be used for both.
CREATE OR REPLACE FUNCTION api.geocode_parts(
	house_number text,
	street_name text,
	street_suffix text DEFAULT NULL,
	pre_direction text DEFAULT NULL,
	post_direction text DEFAULT NULL,
	city_name text DEFAULT NULL,
	state_code text DEFAULT NULL,
	zip_code text DEFAULT NULL,
	max_results integer DEFAULT 1
)
RETURNS TABLE (
	rating integer,
	longitude double precision,
	latitude double precision,
	street_number text,
	street text,
	street_type text,
	city text,
	state text,
	zip text,
	formatted text
)
LANGUAGE sql
STABLE
PARALLEL SAFE
SET search_path = tiger, public
AS $$
	-- Field order is norm_addy's. address/address_alphanumeric follow the
	-- parser: the leading digits as the integer, the raw token alongside, since
	-- matching reads only the integer.
	SELECT n.*
	FROM api.geocode_normalized(
		ROW(
			substring(geocode_parts.house_number FROM '^[0-9]+')::integer,
			geocode_parts.pre_direction,
			geocode_parts.street_name,
			geocode_parts.street_suffix,
			geocode_parts.post_direction,
			NULL,
			geocode_parts.city_name,
			geocode_parts.state_code,
			left(geocode_parts.zip_code, 5),
			true,
			substring(geocode_parts.zip_code FROM '^[0-9]{5}-?([0-9]{4})$'),
			geocode_parts.house_number
		)::tiger.norm_addy,
		geocode_parts.max_results
	) AS n;
$$;

COMMENT ON FUNCTION api.geocode_parts(text, text, text, text, text, text, text, text, integer) IS
	'Geocode an address already split into components, bypassing the free-text parser. Suffix abbreviated as USPS does (St, Ave); zip may be 5 or 9 digits.';

CREATE OR REPLACE FUNCTION api.reverse_geocode(
	longitude double precision,
	latitude double precision,
	max_results integer DEFAULT 1
)
RETURNS TABLE (
	distance_metres double precision,
	street_number text,
	street text,
	street_type text,
	city text,
	state text,
	zip text,
	formatted text
)
LANGUAGE sql
STABLE
PARALLEL SAFE
SET search_path = tiger, public
AS $$
	WITH query AS (
		SELECT ST_Transform(
			ST_SetSRID(
				ST_MakePoint(
					reverse_geocode.longitude,
					reverse_geocode.latitude
				), 4326
			), 4269
		) AS geom
	), hit AS (
		SELECT r.intpt, r.addy
		FROM query, reverse_geocode(query.geom, false) AS r
	)
	-- Subscript rather than unnest: unnest() on an array of a composite type
	-- expands each element into its own fields, so a column alias list binds
	-- norm_addy's first field, not the row. generate_subscripts also keeps addy
	-- and intpt aligned, which is the property the distance calculation needs.
	SELECT
		ST_Distance(query.geom::geography, hit.intpt[i]::geography)::double precision,
		COALESCE((hit.addy[i]).address_alphanumeric, (hit.addy[i]).address::text),
		(hit.addy[i]).streetname::text,
		(hit.addy[i]).streettypeabbrev::text,
		(hit.addy[i]).location::text,
		(hit.addy[i]).stateabbrev::text,
		(hit.addy[i]).zip::text,
		pprint_addy(hit.addy[i])
	FROM query, hit, generate_subscripts(hit.addy, 1) AS i
	ORDER BY 1
	LIMIT reverse_geocode.max_results;
$$;

COMMENT ON FUNCTION api.reverse_geocode(double precision, double precision, integer) IS
	'Nearest addresses to a WGS84 point, closest first.';

-- Coverage is a property of which states have been loaded, not of the image, so
-- it has to be recorded as loads happen. tiger-load writes here on success; the
-- gRPC service reports it so a caller can tell "no such address" apart from
-- "that state was never loaded".
CREATE TABLE IF NOT EXISTS api.load_log (
	state text PRIMARY KEY,
	tiger_year text NOT NULL,
	loaded_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE api.load_log IS
	'One row per state successfully loaded, written by tiger-load.';

CREATE OR REPLACE FUNCTION api.coverage()
RETURNS TABLE (
	state text,
	tiger_year text,
	loaded_at timestamptz
)
LANGUAGE sql
STABLE
SET search_path = tiger, public
AS $$
	SELECT l.state, l.tiger_year, l.loaded_at
	FROM api.load_log AS l
	ORDER BY l.state;
$$;

COMMENT ON FUNCTION api.coverage() IS
	'States with loaded TIGER data. Empty until a state load has run.';
