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
	FROM geocode(geocode.address, geocode.max_results) AS g
	ORDER BY g.rating;
$$;

COMMENT ON FUNCTION api.geocode(text, integer) IS
	'Geocode a free-form US address. Lower rating is a better match; 0 is exact.';

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
