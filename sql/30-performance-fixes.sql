-- Three geocoder performance fixes carried here until they land upstream in
-- postgis_tiger_geocoder. All were found by benchmarking the full 56-state load
-- and are written up in tmp/UPSTREAM.md (rsync-only). Remove this file when the
-- installed release includes them.
--
-- Applied by initdb on first boot and by `make schema` on an existing database.
-- ALTER EXTENSION postgis_tiger_geocoder UPDATE reinstalls upstream's versions
-- of these functions and silently undoes this file: run `make schema` after any
-- extension upgrade, and let the test suite's smoke check tell you if you forgot.
--
-- Placeholders that upstream resolves at install time (@extschema:postgis@,
-- @extschema:fuzzystrmatch@) are written as `public` here, which is where
-- docker/initdb/10-geocoder.sh creates both extensions.

-- 1. least_hn / greatest_hn / diff_zip: make them inlinable.
--
-- Each is a one-line SQL function that geocode_address calls several thousand
-- times per geocode inside its ranking expressions. All three were declared
-- IMMUTABLE but called to_number(), which is STABLE (it reads lc_numeric), and
-- PostgreSQL refuses to inline a function that claims more purity than its body
-- has -- so every call was a real function invocation. Two further inliner rules
-- bit on the way to fixing it: a parameter referenced twice is not inlined when
-- its argument is expensive (geocode_address nests these calls), and a STRICT
-- function is not inlined unless its body is strict too (COALESCE and CASE are
-- not). The bodies below satisfy all three: no to_number, each parameter
-- referenced once, diff_zip strict via regexp_replace rather than COALESCE.
-- Contracts unchanged; measured 5,993 -> 45 nested statements per geocode and
-- about +25% throughput.
CREATE OR REPLACE FUNCTION tiger.least_hn(fromhn character varying, tohn character varying)
RETURNS integer
LANGUAGE sql IMMUTABLE PARALLEL SAFE COST 200
AS $$
	SELECT least(
		coalesce(left(substring(trim($1) from '^[0-9]+$'), 8)::integer, 0),
		coalesce(left(substring(trim($2) from '^[0-9]+$'), 8)::integer, 0));
$$;

CREATE OR REPLACE FUNCTION tiger.greatest_hn(fromhn character varying, tohn character varying)
RETURNS integer
LANGUAGE sql IMMUTABLE PARALLEL SAFE COST 200
AS $$
	SELECT greatest(
		coalesce(left(substring(trim($1) from '^[0-9]+$'), 8)::integer, 0),
		coalesce(left(substring(trim($2) from '^[0-9]+$'), 8)::integer, 0));
$$;

CREATE OR REPLACE FUNCTION tiger.diff_zip(zip1 character varying, zip2 character varying)
RETURNS integer
LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT COST 200
AS $$
	SELECT abs(
		regexp_replace(trim(substring($1, 1, 5)), '^(?![0-9]+$).*$', '0')::integer
	  - regexp_replace(trim(substring($2, 1, 5)), '^(?![0-9]+$).*$', '0')::integer);
$$;

-- Self-test: the rewrites must keep upstream's semantics exactly.
DO $$
BEGIN
	IF NOT (tiger.least_hn('100', '198') = 100
		AND tiger.greatest_hn('100', '198') = 198
		AND tiger.least_hn('100A', '198') = 0
		AND tiger.least_hn(NULL, '198') = 0
		AND tiger.least_hn(' 42 ', '7') = 7
		AND tiger.greatest_hn('', NULL) = 0
		AND tiger.least_hn('123456789012', '5') = 5
		AND tiger.diff_zip('20009', '20010') = 1
		AND tiger.diff_zip('20009-1234', '20010') = 1
		AND tiger.diff_zip(NULL, '20009') IS NULL
		AND tiger.diff_zip('ABCDE', '20009') = 20009
		AND tiger.diff_zip('', '5') = 5) THEN
		RAISE EXCEPTION 'tiger helper rewrite changed semantics; see sql/30-performance-fixes.sql';
	END IF;
END
$$;

-- 2. geocode_address: no soundex on a numeric street name in the fallback.
--
-- When the zip-restricted first pass finds nothing, the fallback searches the
-- whole state with soundex(name) = soundex($2). soundex encodes letters only, so
-- for a numbered road soundex('250') is the empty string -- equal to every other
-- numbered road in the state (Indiana has 319,950 numeric-named street rows).
-- One address joined 1.4 million rows and sorted 440,000 of them: 9.4 seconds.
-- numeric_streets_equal() sits in the same disjunction and matches numbered
-- roads correctly, so skipping the soundex term when $2 is numeric removes only
-- noise. Verified by geocoding the same 2,000 addresses before and after: zero
-- matches lost, zero gained; worst case 10.2 s -> 3.2 s, +14% throughput.
--
-- The change is the single line containing:  $2 !~ ''^[0-9]''

-- 3. geocode_address: query the state's own tables, not the inheritance parents.
--
-- Every dynamic statement in geocode_address names the inheritance parents --
-- tiger.featnames, tiger.addr, tiger.edges, tiger.faces, tiger.place and the zip
-- tables -- and filters on statefp. Each parent has one child per loaded state,
-- so with 56 states the planner opens and locks about 280 tables and 2,600
-- indexes per statement before constraint exclusion throws 55 states' worth
-- away; and because the statements are built as strings and run with EXECUTE,
-- no plan is ever cached and the work is repeated on every call.
-- pg_stat_statements with track_planning put planning at ~35 ms of a ~95 ms
-- geocode, 66-97% of the time of the four main statements, and a single
-- geocode took 2,886 locks -- that is the child tables being opened.
--
-- The function already knows the state (in_statefp for the first pass, each
-- zip_state row's statefp in the fallback loop -- a zip can span two states, so
-- the fallback derives it per iteration). When it does, the statements now name
-- tiger_data.<st>_<table> directly and the planner opens a handful of relations
-- instead of ~280. state_table() picks the child, or falls back to the parent
-- when the state is unknown or that state is not loaded. tiger.state,
-- tiger.county and tiger.zcta5 have one national child each and are left alone,
-- as is the static zip_lookup_base lookup that discovers the state in the first
-- place. Same joins, filters and column lists; only the relation names change.
CREATE OR REPLACE FUNCTION tiger.state_table(st text, parent text)
RETURNS text
LANGUAGE sql STABLE
AS $$
	SELECT CASE
		WHEN to_regclass('tiger_data.' || $1 || '_' || $2) IS NOT NULL
			THEN 'tiger_data.' || $1 || '_' || $2
		ELSE 'tiger.' || $2
	END;
$$;

-- Self-test: fall back to the parent for an unknown or unloaded state.
DO $$
BEGIN
	IF NOT (tiger.state_table(NULL, 'featnames') = 'tiger.featnames'
		AND tiger.state_table('no_such_state', 'featnames') = 'tiger.featnames') THEN
		RAISE EXCEPTION 'tiger.state_table does not fall back to the parent; see sql/30-performance-fixes.sql';
	END IF;
END
$$;

-- This is upstream's geocode_address (2025.2) with fixes 2 and 3 applied, so it
-- is long.
CREATE OR REPLACE FUNCTION tiger.geocode_address(IN parsed tiger.norm_addy, max_results integer DEFAULT 10, restrict_geom public.geometry DEFAULT NULL, OUT addy tiger.norm_addy, OUT geomout public.geometry, OUT rating integer)
  RETURNS SETOF record AS
$$
DECLARE
  results RECORD;
  zip_info RECORD;
  stmt VARCHAR;
  in_statefp VARCHAR;
  exact_street boolean := false;
  var_debug boolean := tiger.get_geocode_setting('debug_geocode_address')::boolean;
  var_sql text := '';
  var_n integer := 0;
  var_restrict_geom public.geometry := NULL;
  var_bfilter text := null;
  var_bestrating integer := NULL;
  var_zip_penalty numeric := tiger.get_geocode_setting('zip_penalty')::numeric*1.00;
  var_st text;
  t_featnames text;
  t_addr text;
  t_edges text;
  t_faces text;
  t_place text;
  t_cousub text;
  t_zip_lookup_base text;
  t_zip_state text;
  t_zip_state_loc text;
BEGIN
  IF parsed.streetName IS NULL THEN
    -- A street name must be given.  Think about it.
    RETURN;
  END IF;

  ADDY.internal := parsed.internal;

  IF parsed.stateAbbrev IS NOT NULL THEN
    in_statefp := statefp FROM tiger.state_lookup As s WHERE s.abbrev = parsed.stateAbbrev;
  END IF;

  IF in_statefp IS NULL THEN
  --if state is not provided or was bogus, just pick the first where the zip is present
    in_statefp := statefp FROM tiger.zip_lookup_base WHERE zip = substring(parsed.zip,1,5) LIMIT 1;
  END IF;

  var_st := lower(abbrev) FROM tiger.state_lookup As s WHERE s.statefp = in_statefp;
  t_featnames := tiger.state_table(var_st, 'featnames');
  t_addr := tiger.state_table(var_st, 'addr');
  t_edges := tiger.state_table(var_st, 'edges');
  t_faces := tiger.state_table(var_st, 'faces');
  t_place := tiger.state_table(var_st, 'place');
  t_zip_lookup_base := tiger.state_table(var_st, 'zip_lookup_base');
  t_zip_state := tiger.state_table(var_st, 'zip_state');
  t_zip_state_loc := tiger.state_table(var_st, 'zip_state_loc');

  IF restrict_geom IS NOT NULL THEN
  		IF public.ST_SRID(restrict_geom) < 1 OR public.ST_SRID(restrict_geom) = 4236 THEN
  		-- basically has no srid or if wgs84 close enough to NAD 83 -- assume same as data
  			var_restrict_geom = public.ST_SetSRID(restrict_geom,4269);
  		ELSE
  		--transform and snap
  			var_restrict_geom = public.ST_SnapToGrid(public.ST_Transform(restrict_geom, 4269), 0.000001);
  		END IF;
  END IF;
  var_bfilter := ' SELECT zcta5ce FROM tiger.zcta5 AS zc
                    WHERE zc.statefp = ' || quote_nullable(in_statefp) || '
                        AND public.ST_Intersects(zc.the_geom, ' || quote_literal(var_restrict_geom::text) || '::public.geometry)  ' ;

  SELECT NULL::varchar[] As zip INTO zip_info;

  IF parsed.zip IS NOT NULL  THEN
  -- Create an array of 5 zips containing 2 before and 2 after our target if our streetName is longer
    IF length(parsed.streetName) > 7 THEN
        SELECT tiger.zip_range(parsed.zip, -2, 2) As zip INTO zip_info;
    ELSE
    -- If our street name is short, we'll run into many false positives so reduce our zip window a bit
        SELECT tiger.zip_range(parsed.zip, -1, 1) As zip INTO zip_info;
    END IF;
    --This signals bad zip input, only use the range if it falls in the place zip range
    IF length(parsed.zip) != 5 AND parsed.location IS NOT NULL THEN
         stmt := 'SELECT ARRAY(SELECT DISTINCT zip
          FROM ' || t_zip_lookup_base || ' AS z
         WHERE z.statefp = $1
               AND  z.zip = ANY($3) AND lower(z.city) LIKE lower($2) || ''%''::text '  || COALESCE(' AND z.zip IN(' || var_bfilter || ')', '') || ')::varchar[] AS zip ORDER BY zip' ;
         EXECUTE stmt INTO zip_info USING in_statefp, parsed.location, zip_info.zip;
         IF var_debug THEN
            RAISE NOTICE 'Bad zip newzip range: %', quote_nullable(zip_info.zip);
         END IF;
        IF array_upper(zip_info.zip,1) = 0 OR array_upper(zip_info.zip,1) IS NULL THEN
        -- zips do not fall in city ignore them
            IF var_debug THEN
                RAISE NOTICE 'Ignore new zip range that is bad too: %', quote_nullable(zip_info.zip);
            END IF;
            zip_info.zip = NULL::varchar[];
        END IF;
    END IF;
  END IF;
  IF zip_info.zip IS NULL THEN
  -- If no good zips just include all for the location
  -- We do a like instead of absolute check since tiger sometimes tacks things like Town at end of places
    stmt := 'SELECT ARRAY(SELECT DISTINCT zip
          FROM ' || t_zip_lookup_base || ' AS z
         WHERE z.statefp = $1
               AND  lower(z.city) LIKE lower($2) || ''%''::text '  || COALESCE(' AND z.zip IN(' || var_bfilter || ')', '') || ')::varchar[] AS zip ORDER BY zip' ;
    EXECUTE stmt INTO zip_info USING in_statefp, parsed.location;
    IF var_debug THEN
        RAISE NOTICE 'Zip range based on only considering city: %', quote_nullable(zip_info.zip);
    END IF;
  END IF;
   -- Brute force -- try to find perfect matches and exit if we have one
   -- we first pull all the names in zip and rank by if zip matches input zip and streetname matches street
  stmt := 'WITH a AS
  	( SELECT *
  		FROM (SELECT f.*, ad.side, ad.zip, ad.fromhn, ad.tohn,
  					RANK() OVER(ORDER BY ' || CASE WHEN parsed.zip > '' THEN ' tiger.diff_zip(ad.zip,$7)*$11 + ' ELSE '' END
						||' CASE WHEN lower(f.name) = lower($2) THEN 0 ELSE tiger.levenshtein_ignore_case(f.name, lower($2) )  END +
						tiger.levenshtein_ignore_case(f.fullname, lower($2 || '' '' || COALESCE($4,'''')) )
						+ CASE WHEN (tiger.greatest_hn(ad.fromhn,ad.tohn) % 2)::integer = ($1 % 2)::integer THEN 0 ELSE 1 END
						+ CASE WHEN $1::integer BETWEEN tiger.least_hn(ad.fromhn,ad.tohn) AND tiger.greatest_hn(ad.fromhn, ad.tohn)
							THEN 0 ELSE 4 END
							+ CASE WHEN lower($4) = lower(f.suftypabrv) OR lower($4) = lower(f.pretypabrv) THEN 0 ELSE 1 END
							+ tiger.rate_attributes($5, f.predirabrv,'
         || '    $2,  f.name , $4,'
         || '    suftypabrv , $6,'
         || '    sufdirabrv, prequalabr)
							)
						As rank
                		FROM ' || t_featnames || ' As f INNER JOIN ' || t_addr || ' As ad ON (f.tlid = ad.tlid)
                    WHERE $10 = f.statefp AND $10 = ad.statefp
                    	'
                    || CASE WHEN length(parsed.streetName) > 5  THEN ' AND (lower(f.fullname) LIKE (COALESCE($5 || '' '','''') || lower($2) || ''%'')::text OR lower(f.name) = lower($2) OR public.soundex(f.name) = public.soundex($2) ) ' ELSE  ' AND lower(f.name) = lower($2) ' END
                    || CASE WHEN zip_info.zip IS NOT NULL THEN '    AND ( ad.zip = ANY($9::varchar[]) )  ' ELSE '' END
            || ' ) AS foo ORDER BY rank LIMIT ' || max_results*3 || ' )
  	SELECT * FROM (
    SELECT DISTINCT ON (sub.predirabrv,sub.fename,COALESCE(sub.suftypabrv, sub.pretypabrv) ,sub.sufdirabrv,sub.place,s.stusps,sub.zip)'
         || '    sub.predirabrv   as fedirp,'
         || '    sub.fename,'
         || '    COALESCE(sub.suftypabrv, sub.pretypabrv)   as fetype,'
         || '    sub.sufdirabrv   as fedirs,'
         || '    sub.place ,'
         || '    s.stusps as state,'
         || '    sub.zip as zip,'
         || '    tiger.interpolate_from_address($1, sub.fromhn,'
         || '        sub.tohn, sub.the_geom, sub.side) as address_geom,'
         || '       (sub.sub_rating + '
         || CASE WHEN parsed.zip > '' THEN '  least(coalesce(tiger.diff_zip($7 , sub.zip),0), 20)*$11  '
            ELSE '1' END::text
         || ' + coalesce(tiger.levenshtein_ignore_case($3, sub.place),5) )::integer'
         || '    as sub_rating,'
         || '    sub.exact_address as exact_address, sub.tohn, sub.fromhn '
         || ' FROM ('
         || '  SELECT tlid, predirabrv, COALESCE(b.prequalabr || '' '','''' ) || b.name As fename, suftypabrv, sufdirabrv, fromhn, tohn,
                    side,  zip, tiger.rate_attributes($5, predirabrv,'
         || '    $2,  b.name , $4,'
         || '    suftypabrv , $6,'
         || '    sufdirabrv, prequalabr) + '
         || '    CASE '
         || '        WHEN $1::integer IS NULL OR b.fromhn IS NULL THEN 20'
         || '        WHEN $1::integer >= tiger.least_hn(b.fromhn, b.tohn) '
         || '            AND $1::integer <= tiger.greatest_hn(b.fromhn,b.tohn)'
         || '            AND ($1::integer % 2) = (to_number(b.fromhn,''99999999'') % 2)::integer'
         || '            THEN 0'
         || '        WHEN $1::integer >= tiger.least_hn(b.fromhn,b.tohn)'
         || '            AND $1::integer <= tiger.greatest_hn(b.fromhn,b.tohn)'
         || '            THEN 2'
         || '        ELSE'
         || '            ((1.0 - '
         ||              '(tiger.least_hn($1::text,tiger.least_hn(b.fromhn,b.tohn)::text)::numeric /'
         ||              ' (greatest(1,tiger.greatest_hn($1::text,tiger.greatest_hn(b.fromhn,b.tohn)::text))) )'
         ||              ') * 5)::integer + 5'
         || '        END::integer'
         || '    AS sub_rating,$1::integer >= tiger.least_hn(b.fromhn,b.tohn) '
         || '            AND $1::integer <= tiger.greatest_hn(b.fromhn,b.tohn) '
         || '            AND ($1 % 2)::numeric::integer = (to_number(b.fromhn,''99999999'') % 2)'
         || '    as exact_address, b.name, b.prequalabr, b.pretypabrv, b.tfidr, b.tfidl, b.the_geom, b.place '
         || '  FROM
             (SELECT   a.tlid, a.fullname, a.name, a.predirabrv, a.suftypabrv, a.sufdirabrv, a.prequalabr, a.pretypabrv,
                b.the_geom, tfidr, tfidl,
                a.side ,
                a.fromhn,
                a.tohn,
                a.zip,
                p.name as place

                FROM  a INNER JOIN ' || t_edges || ' As b ON (a.statefp = b.statefp AND a.tlid = b.tlid  '
               || ')
                    INNER JOIN ' || t_faces || ' AS f ON ($10 = f.statefp AND ( (b.tfidl = f.tfid AND a.side = ''L'') OR (b.tfidr = f.tfid AND a.side = ''R'' ) ))
                    INNER JOIN ' || t_place || ' p ON ($10 = p.statefp AND f.placefp = p.placefp '
          || CASE WHEN parsed.location > '' AND zip_info.zip IS NULL THEN ' AND ( lower(p.name) LIKE (lower($3::text) || ''%'')  ) ' ELSE '' END
          || ')
                WHERE a.statefp = $10  AND  b.statefp = $10   '
             ||   CASE WHEN var_restrict_geom IS NOT NULL THEN ' AND public.ST_Intersects(b.the_geom, $8::public.geometry) '  ELSE '' END
             || '

          )   As b
           ORDER BY 10 ,  11 DESC
           LIMIT 20
            ) AS sub
          JOIN tiger.state s ON ($10 = s.statefp)
            ORDER BY 1,2,3,4,5,6,7,9
          LIMIT 20) As foo ORDER BY sub_rating, exact_address DESC LIMIT  ' || max_results*10 ;

  IF var_debug THEN
         RAISE NOTICE 'stmt: %',
            replace( replace( replace(
                replace(
                replace(replace( replace(replace(replace(replace( replace(stmt,'$11', var_zip_penalty::text), '$10', quote_nullable(in_statefp) ), '$2',quote_nullable(parsed.streetName)),'$3',
                quote_nullable(parsed.location)), '$4', quote_nullable(parsed.streetTypeAbbrev) ),
                '$5', quote_nullable(parsed.preDirAbbrev) ),
                   '$6', quote_nullable(parsed.postDirAbbrev) ),
                   '$7', quote_nullable(parsed.zip) ),
                   '$8', quote_nullable(var_restrict_geom::text) ),
                   '$9', quote_nullable(zip_info.zip) ), '$1', quote_nullable(parsed.address) );
        --RAISE NOTICE 'PREPARE query_base_geo(integer, varchar,varchar,varchar,varchar,varchar,varchar,geometry,varchar[]) As %', stmt;
        --RAISE NOTICE 'EXECUTE query_base_geo(%,%,%,%,%,%,%,%,%); ', parsed.address,quote_nullable(parsed.streetName), quote_nullable(parsed.location), quote_nullable(parsed.streetTypeAbbrev), quote_nullable(parsed.preDirAbbrev), quote_nullable(parsed.postDirAbbrev), quote_nullable(parsed.zip), quote_nullable(var_restrict_geom::text), quote_nullable(zip_info.zip);
        --RAISE NOTICE 'DEALLOCATE query_base_geo;';
    END IF;
    FOR results IN EXECUTE stmt USING parsed.address,parsed.streetName, parsed.location, parsed.streetTypeAbbrev, parsed.preDirAbbrev, parsed.postDirAbbrev, parsed.zip, var_restrict_geom, zip_info.zip, in_statefp, var_zip_penalty LOOP

        -- If we found a match with an exact street, then don't bother
        -- trying to do non-exact matches

        exact_street := true;

        IF results.exact_address THEN
            ADDY.address := parsed.address;
        ELSE
            ADDY.address := CASE WHEN parsed.address > to_number(results.tohn,'99999999') AND parsed.address > to_number(results.fromhn, '99999999') THEN tiger.greatest_hn(results.fromhn, results.tohn)::integer
                ELSE tiger.least_hn(results.fromhn, results.tohn)::integer END ;
        END IF;

        ADDY.preDirAbbrev     := results.fedirp;
        ADDY.streetName       := results.fename;
        ADDY.streetTypeAbbrev := results.fetype;
        ADDY.postDirAbbrev    := results.fedirs;
        ADDY.location         := results.place;
        ADDY.stateAbbrev      := results.state;
        ADDY.zip              := results.zip;
        ADDY.parsed := TRUE;

        GEOMOUT := results.address_geom;
        RATING := results.sub_rating::integer;
        var_n := var_n + 1;

        IF var_bestrating IS NULL THEN
            var_bestrating := RATING; /** the first record to come is our best rating we will ever get **/
        END IF;

        -- Only consider matches with decent ratings
        IF RATING < 90 THEN
            RETURN NEXT;
        END IF;

        -- If we get an exact match, then just return that
        IF RATING = 0 THEN
            RETURN;
        END IF;

        IF var_n >= max_results AND RATING < 10  THEN --we have exceeded our desired limit and rating is not horrible
            RETURN;
        END IF;

    END LOOP;

    IF var_bestrating < 30 THEN --if we already have a match with a rating of 30 or less, its unlikely we can do any better
        RETURN;
    END IF;

-- There are a couple of different things to try, from the highest preference and falling back
  -- to lower-preference options.
  -- We start out with zip-code matching, where the zip code could possibly be in more than one
  -- state.  We loop through each state its in.
  -- Next, we try to find the location in our side-table, which is based off of the 'place' data exact first then sounds like
  -- Next, we look up the location/city and use the zip code which is returned from that
  -- Finally, if we didn't get a zip code or a city match, we fall back to just a location/street
  -- lookup to try and find *something* useful.
  -- In the end, we *have* to find a statefp, one way or another.
  var_sql :=
  ' SELECT statefp,location,a.zip,exact,min(pref) FROM
    (SELECT zip_state.statefp as statefp,$1 as location, true As exact, ARRAY[zip_state.zip] as zip,1 as pref
        FROM ' || t_zip_state || ' AS zip_state WHERE zip_state.zip = $2
            AND (' || quote_nullable(in_statefp) || ' IS NULL OR zip_state.statefp = ' || quote_nullable(in_statefp) || ')
          ' || COALESCE(' AND zip_state.zip IN(' || var_bfilter || ')', '') ||
        ' UNION SELECT zip_state_loc.statefp,zip_state_loc.place As location,false As exact, array_agg(zip_state_loc.zip) AS zip,1 + abs(COALESCE(tiger.diff_zip(max(zip), $2),0) - COALESCE(tiger.diff_zip(min(zip), $2),0))*$3 As pref
              FROM ' || t_zip_state_loc || ' AS zip_state_loc
             WHERE zip_state_loc.statefp = ' || quote_nullable(in_statefp) || '
                   AND lower($1) = lower(zip_state_loc.place) '  || COALESCE(' AND zip_state_loc.zip IN(' || var_bfilter || ')', '') ||
        '     GROUP BY zip_state_loc.statefp,zip_state_loc.place
      UNION SELECT zip_state_loc.statefp,zip_state_loc.place As location,false As exact, array_agg(zip_state_loc.zip),3
              FROM ' || t_zip_state_loc || ' AS zip_state_loc
             WHERE zip_state_loc.statefp = ' || quote_nullable(in_statefp) || '
                   AND public.soundex($1) = public.soundex(zip_state_loc.place)
             GROUP BY zip_state_loc.statefp,zip_state_loc.place
      UNION SELECT zip_lookup_base.statefp,zip_lookup_base.city As location,false As exact, array_agg(zip_lookup_base.zip),4
              FROM ' || t_zip_lookup_base || ' AS zip_lookup_base
             WHERE zip_lookup_base.statefp = ' || quote_nullable(in_statefp) || '
                         AND (public.soundex($1) = public.soundex(zip_lookup_base.city) OR public.soundex($1) = public.soundex(zip_lookup_base.county))
             GROUP BY zip_lookup_base.statefp,zip_lookup_base.city
      UNION SELECT ' || quote_nullable(in_statefp) || ' As statefp,$1 As location,false As exact,NULL, 5) as a '
      ' WHERE a.statefp IS NOT NULL
      GROUP BY statefp,location,a.zip,exact, pref ORDER BY exact desc, pref, zip';
  /** FOR zip_info IN     SELECT statefp,location,zip,exact,min(pref) FROM
    (SELECT tiger.zip_state.statefp as statefp,parsed.location as location, true As exact, ARRAY[tiger.zip_state.zip] as zip,1 as pref
        FROM tiger.zip_state WHERE tiger.zip_state.zip = parsed.zip
            AND (in_statefp IS NULL OR tiger.zip_state.statefp = in_statefp)
        UNION SELECT tiger.zip_state_loc.statefp,parsed.location,false As exact, array_agg(tiger.zip_state_loc.zip),2 + tiger.diff_zip(zip[1], parsed.zip)
              FROM tiger.zip_state_loc
             WHERE tiger.zip_state_loc.statefp = in_statefp
                   AND lower(parsed.location) = lower(tiger.zip_state_loc.place)
             GROUP BY tiger.zip_state_loc.statefp,parsed.location
      UNION SELECT tiger.zip_state_loc.statefp,parsed.location,false As exact, array_agg(tiger.zip_state_loc.zip),3
              FROM tiger.zip_state_loc
             WHERE tiger.zip_state_loc.statefp = in_statefp
                   AND public.soundex(parsed.location) = public.soundex(tiger.zip_state_loc.place)
             GROUP BY tiger.zip_state_loc.statefp,parsed.location
      UNION SELECT tiger.zip_lookup_base.statefp,parsed.location,false As exact, array_agg(tiger.zip_lookup_base.zip),4
              FROM tiger.zip_lookup_base
             WHERE tiger.zip_lookup_base.statefp = in_statefp
                         AND (public.soundex(parsed.location) = public.soundex(tiger.zip_lookup_base.city) OR public.soundex(parsed.location) = public.soundex(tiger.zip_lookup_base.county))
             GROUP BY tiger.zip_lookup_base.statefp,parsed.location
      UNION SELECT in_statefp,parsed.location,false As exact,NULL, 5) as a
        --JOIN (VALUES (true),(false)) as b(exact) on TRUE
      WHERE statefp IS NOT NULL
      GROUP BY statefp,location,zip,exact, pref ORDER BY exact desc, pref, zip  **/
  FOR zip_info IN EXECUTE var_sql USING parsed.location, parsed.zip, var_zip_penalty  LOOP
    var_st := lower(abbrev) FROM tiger.state_lookup As s WHERE s.statefp = zip_info.statefp;
    t_featnames := tiger.state_table(var_st, 'featnames');
    t_addr := tiger.state_table(var_st, 'addr');
    t_edges := tiger.state_table(var_st, 'edges');
    t_faces := tiger.state_table(var_st, 'faces');
    t_place := tiger.state_table(var_st, 'place');
    t_cousub := tiger.state_table(var_st, 'cousub');
    t_zip_lookup_base := tiger.state_table(var_st, 'zip_lookup_base');
  -- For zip distance metric we consider both the distance of zip based on numeric as well aa levenshtein
  -- We use the prequalabr (these are like Old, that may or may not appear in front of the street name)
  -- We also treat pretypabr as fetype since in normalize we treat these as streetypes  and highways usually have the type here
  -- In pprint_addy we changed to put it in front if it is a is_hw type
    stmt := 'SELECT DISTINCT ON (sub.predirabrv,sub.fename,COALESCE(sub.suftypabrv, sub.pretypabrv) ,sub.sufdirabrv,coalesce(p.name,cs.name,zip.city,co.name),s.stusps,sub.zip)'
         || '    sub.predirabrv   as fedirp,'
         || '    sub.fename,'
         || '    COALESCE(sub.suftypabrv, sub.pretypabrv)   as fetype,'
         || '    sub.sufdirabrv   as fedirs,'
         || '    coalesce(p.name,cs.name,zip.city,co.name)::varchar as place,'
         || '    s.stusps as state,'
         || '    sub.zip as zip,'
         || '    tiger.interpolate_from_address($1, sub.fromhn,'
         || '        sub.tohn, e.the_geom, sub.side) as address_geom,'
         || '       (sub.sub_rating + '
         || CASE WHEN parsed.zip > '' THEN '  least((coalesce(tiger.diff_zip($7 , sub.zip),0) *$9)::integer, coalesce(tiger.levenshtein_ignore_case($7, sub.zip)*$9,0) ) '
            ELSE '3' END::text
         || ' + coalesce(least(tiger.levenshtein_ignore_case($3, coalesce(p.name,cs.name,zip.city,co.name)), tiger.levenshtein_ignore_case($3, coalesce(cs.name,co.name))),5) )::integer'
         || '    as sub_rating,'
         || '    sub.exact_address as exact_address '
         || ' FROM ('
         || '  SELECT a.tlid, predirabrv, COALESCE(a.prequalabr || '' '','''' ) || a.name As fename, suftypabrv, sufdirabrv, fromhn, tohn,
                    side, a.statefp, zip, tiger.rate_attributes($5, a.predirabrv,'
         || '    $2,  a.name , $4,'
         || '    a.suftypabrv , $6,'
         || '    a.sufdirabrv, a.prequalabr) + '
         || '    CASE '
         || '        WHEN $1::integer IS NULL OR b.fromhn IS NULL THEN 20'
         || '        WHEN $1::integer >= tiger.least_hn(b.fromhn, b.tohn) '
         || '            AND $1::integer <= tiger.greatest_hn(b.fromhn,b.tohn)'
         || '            AND ($1::integer % 2) = (to_number(b.fromhn,''99999999'') % 2)::integer'
         || '            THEN 0'
         || '        WHEN $1::integer >= tiger.least_hn(b.fromhn,b.tohn)'
         || '            AND $1::integer <= tiger.greatest_hn(b.fromhn,b.tohn)'
         || '            THEN 2'
         || '        ELSE'
         || '            ((1.0 - '
         ||              '(tiger.least_hn($1::text,tiger.least_hn(b.fromhn,b.tohn)::text)::numeric /'
         ||              ' greatest(1,tiger.greatest_hn($1::text,tiger.greatest_hn(b.fromhn,b.tohn)::text)))'
         ||              ') * 5)::integer + 5'
         || '        END'
         || '    as sub_rating,$1::integer >= tiger.least_hn(b.fromhn,b.tohn) '
         || '            AND $1::integer <= tiger.greatest_hn(b.fromhn,b.tohn) '
         || '            AND ($1 % 2)::numeric::integer = (to_number(b.fromhn,''99999999'') % 2)'
         || '    as exact_address, a.name, a.prequalabr, a.pretypabrv '
         || '  FROM ' || t_featnames || ' a join ' || t_addr || ' b ON (a.tlid = b.tlid AND a.statefp = b.statefp  )'
         || '  WHERE'
         || '        a.statefp = ' || quote_literal(zip_info.statefp) || ' AND a.mtfcc LIKE ''S%''  '
         || coalesce('    AND b.zip IN (''' || array_to_string(zip_info.zip,''',''') || ''') ','')
         || CASE WHEN zip_info.exact
                 THEN '    AND ( lower($2) = lower(a.name) OR  ( a.prequalabr > '''' AND trim(lower($2), lower(a.prequalabr) || '' '') = lower(a.name) ) OR tiger.numeric_streets_equal($2, a.name) ) '
                 ELSE '    AND ( ($2 !~ ''^[0-9]'' AND public.soundex($2) = public.soundex(a.name))  OR ( (length($2) > 15 or (length($2) > 7 AND a.prequalabr > '''') ) AND lower(a.fullname) LIKE lower(substring($2,1,15)) || ''%'' ) OR  tiger.numeric_streets_equal($2, a.name) ) '
            END
         || '  ORDER BY 11'
         || '  LIMIT 200'
         || '    ) AS sub'
         || '  JOIN ' || t_edges || ' e ON (' || quote_literal(zip_info.statefp) || ' = e.statefp AND sub.tlid = e.tlid AND e.mtfcc LIKE ''S%'' '
         ||   CASE WHEN var_restrict_geom IS NOT NULL THEN ' AND public.ST_Intersects(e.the_geom, $8) '  ELSE '' END || ') '
         || '  JOIN tiger.state s ON (' || quote_literal(zip_info.statefp) || ' = s.statefp)'
         || '  JOIN ' || t_faces || ' f ON (' || quote_literal(zip_info.statefp) || ' = f.statefp AND (e.tfidl = f.tfid OR e.tfidr = f.tfid))'
         || '  LEFT JOIN ' || t_zip_lookup_base || ' zip ON (sub.zip = zip.zip AND zip.statefp=' || quote_literal(zip_info.statefp) || ')'
         || '  LEFT JOIN ' || t_place || ' p ON (' || quote_literal(zip_info.statefp) || ' = p.statefp AND f.placefp = p.placefp)'
         || '  LEFT JOIN tiger.county co ON (' || quote_literal(zip_info.statefp) || ' = co.statefp AND f.countyfp = co.countyfp)'
         || '  LEFT JOIN ' || t_cousub || ' cs ON (' || quote_literal(zip_info.statefp) || ' = cs.statefp AND cs.cosbidfp = sub.statefp || co.countyfp || f.cousubfp)'
         || ' WHERE'
         || '  ( (sub.side = ''L'' and e.tfidl = f.tfid) OR (sub.side = ''R'' and e.tfidr = f.tfid) ) '
         || ' ORDER BY 1,2,3,4,5,6,7,9'
         || ' LIMIT 10'
         ;
    IF var_debug THEN
        RAISE NOTICE '%', stmt;
        RAISE NOTICE 'PREPARE query_base_geo(integer, varchar,varchar,varchar,varchar,varchar,varchar,geometry,numeric) As %', stmt;
        RAISE NOTICE 'EXECUTE query_base_geo(%,%,%,%,%,%,%,%,%); ', parsed.address,quote_nullable(parsed.streetName), quote_nullable(parsed.location), quote_nullable(parsed.streetTypeAbbrev), quote_nullable(parsed.preDirAbbrev), quote_nullable(parsed.postDirAbbrev), quote_nullable(parsed.zip), quote_nullable(var_restrict_geom::text), quote_nullable(var_zip_penalty);
        RAISE NOTICE 'DEALLOCATE query_base_geo;';
    END IF;
    -- If we got an exact street match then when we hit the non-exact
    -- set of tests, just drop out.
    IF NOT zip_info.exact AND exact_street THEN
        RETURN;
    END IF;

    FOR results IN EXECUTE stmt USING parsed.address,parsed.streetName, parsed.location, parsed.streetTypeAbbrev, parsed.preDirAbbrev, parsed.postDirAbbrev, parsed.zip, var_restrict_geom, var_zip_penalty LOOP

      -- If we found a match with an exact street, then don't bother
      -- trying to do non-exact matches
      IF zip_info.exact THEN
        exact_street := true;
      END IF;

      IF results.exact_address THEN
        ADDY.address := substring(parsed.address::text FROM '[0-9]+')::integer;
      ELSE
        ADDY.address := NULL;
      END IF;

      ADDY.preDirAbbrev     := results.fedirp;
      ADDY.streetName       := results.fename;
      ADDY.streetTypeAbbrev := results.fetype;
      ADDY.postDirAbbrev    := results.fedirs;
      ADDY.location         := results.place;
      ADDY.stateAbbrev      := results.state;
      ADDY.zip              := results.zip;
      ADDY.parsed := TRUE;

      GEOMOUT := results.address_geom;
      RATING := results.sub_rating::integer;
      var_n := var_n + 1;

      -- If our ratings go above 99 exit because its a really bad match
      IF RATING > 99 THEN
        RETURN;
      END IF;

      RETURN NEXT;

      -- If we get an exact match, then just return that
      IF RATING = 0 THEN
        RETURN;
      END IF;

    END LOOP;
    IF var_n > max_results  THEN --we have exceeded our desired limit
        RETURN;
    END IF;
  END LOOP;

  RETURN;
END;
$$
  LANGUAGE 'plpgsql' STABLE COST 1000 ROWS 50 PARALLEL SAFE;

