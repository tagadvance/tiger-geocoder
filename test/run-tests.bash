#!/usr/bin/env bash
# Test suite for the tiger-geocoder image. Runs against the compose stack.
#
# Tests are in two tiers: structural ones that pass on an empty database, and
# data ones that need the nation load plus DC. The data tier is skipped rather
# than failed when DC is absent, so `make test` is useful immediately after
# `make up` and gets stricter as data arrives.
set -euo pipefail

read -ra COMPOSE <<<"${COMPOSE_CMD:-docker compose}"
passed=0
failed=0
skipped=0

query() {
  "${COMPOSE[@]}" exec --no-TTY --user postgres db \
    psql --no-align --tuples-only --no-psqlrc --set ON_ERROR_STOP=1 --command "$1"
}

expect_true() {
  local name=$1 sql=$2 actual
  # A SQL error must fail this test, not the suite: a plain assignment under
  # set -e and pipefail would exit here with no FAIL line and no summary.
  actual=$(query "$sql" 2>&1 | tr --delete '[:space:]') || actual="error:${actual:0:60}"
  if [[ $actual == "t" ]]; then
    printf 'ok       %s\n' "$name"
    passed=$((passed + 1))
  else
    printf 'FAIL     %s (got %q)\n' "$name" "$actual"
    failed=$((failed + 1))
  fi
}

skip() {
  printf 'skip     %s\n' "$1"
  skipped=$((skipped + 1))
}

echo "-- structure"

expect_true "postgis_tiger_geocoder is the standalone 2025.x release" \
  "SELECT extversion LIKE '2025.%' FROM pg_extension WHERE extname = 'postgis_tiger_geocoder'"

expect_true "address_standardizer is installed" \
  "SELECT count(*) = 1 FROM pg_extension WHERE extname = 'address_standardizer'"

expect_true "tiger is on the database search_path" \
  "SELECT current_setting('search_path') LIKE '%tiger%'"

expect_true "the docker loader profile exists" \
  "SELECT count(*) = 1 FROM tiger.loader_platform WHERE os = 'docker'"

expect_true "the loader profile targets the local socket, not localhost" \
  "SELECT declare_sect LIKE '%/var/run/postgresql%'
   FROM tiger.loader_platform WHERE os = 'docker'"

expect_true "the TIGER vintage matches the extension release" \
  "SELECT tiger_year = '2025' AND website_root LIKE '%TIGER2025'
   FROM tiger.loader_variables"

# Needs no data: pure string parsing. This is the upstream smoke test.
expect_true "normalize_address parses a street address" \
  "SELECT streetname = 'Devonshire' AND streettypeabbrev = 'Pl' AND zip = '02109'
   FROM normalize_address('1 Devonshire Place, Boston, MA 02109')"

expect_true "the api schema is present" \
  "SELECT count(*) = 5 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'api' AND p.proname IN ('geocode', 'geocode_parts', 'geocode_normalized', 'reverse_geocode', 'coverage')"

expect_true "the structured geocode entry point has the documented signature" \
  "SELECT to_regprocedure('api.geocode_parts(text, text, text, text, text, text, text, text, integer)') IS NOT NULL"

# With neither state nor zip, upstream returns before touching a table, so this
# runs on an empty database and proves the norm_addy row construction casts.
expect_true "geocode_parts builds a norm_addy without data" \
  "SELECT count(*) = 0 FROM api.geocode_parts('600A', 'Sheridan', 'St', 'N')"

# sql/30-performance-fixes.sql overrides four extension functions. An
# ALTER EXTENSION ... UPDATE silently reinstalls upstream's versions; this is
# how you find out.
expect_true "the geocoder performance fixes are applied (run make schema if not)" \
  "SELECT (SELECT prosrc LIKE '%substring(trim(%' FROM pg_proc WHERE proname = 'least_hn')
      AND (SELECT prosrc LIKE '%regexp_replace(trim(substring(%' FROM pg_proc WHERE proname = 'diff_zip')
      AND (SELECT prosrc LIKE '%\$2 !~ ''''^[0-9]''''%' FROM pg_proc WHERE proname = 'geocode_address')"

expect_true "the not-published ledger is present" \
  "SELECT to_regclass('api.not_published') IS NOT NULL
   AND to_regproc('api.record_not_published') IS NOT NULL"

expect_true "the completeness verifier is present" \
  "SELECT count(*) = 2 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'api' AND p.proname IN ('verify_state', 'state_is_complete')"

# Tuning is computed at startup, so the values are host-dependent and cannot be
# asserted exactly. What is assertable is that it ran at all: 128MB is the stock
# default, and finding it means tiger-tune was skipped or silently failed.
expect_true "the server was tuned for this host" \
  "SELECT setting::bigint * 8192 > 128 * 1024 * 1024 FROM pg_settings
   WHERE name = 'shared_buffers'"

# autovacuum_work_mem defaults to -1, meaning "inherit maintenance_work_mem" --
# per worker. Raising maintenance_work_mem without capping this authorises
# several times that much memory in the background, which is how a tuned server
# gets OOM-killed mid-load rather than at startup where you would notice.
# pg_settings.setting, not current_setting(): the latter renders a unit suffix
# ("1003MB") that will not cast, while both of these are plain kB here.
# One geocode locks every child of five inheritance parents before the planner
# prunes to a state: 2,886 locks, measured on a 56-state load. At the default 64
# the table holds two geocodes and the third fails with "out of shared memory"
# -- found by a benchmark, not by anything single-threaded. The threshold is the
# measured figure, so every connection can geocode at once.
expect_true "the lock table lets every connection geocode at once" \
  "SELECT setting::bigint >= 2886 FROM pg_settings WHERE name = 'max_locks_per_transaction'"

expect_true "autovacuum memory is capped independently of maintenance_work_mem" \
  "SELECT av.setting::bigint > 0 AND av.setting::bigint <= mw.setting::bigint
   FROM pg_settings av, pg_settings mw
   WHERE av.name = 'autovacuum_work_mem' AND mw.name = 'maintenance_work_mem'"

echo "-- data"

# to_regclass rather than a count: tiger_data does not exist until the first
# load, and referencing a missing relation is a parse error, not a false.
if [[ $(query "SELECT to_regclass('tiger_data.state_all') IS NOT NULL" | tr -d '[:space:]') != "t" ]]; then
  skip "nation data (run: make nation)"
  skip "DC geocode (run: make load STATES=DC)"
  skip "DC reverse geocode"
  skip "coverage reporting"
else
  expect_true "the nation load has all states and territories" \
    "SELECT count(*) = 56 FROM tiger_data.state_all"

  expect_true "the nation load has every county" \
    "SELECT count(*) BETWEEN 3200 AND 3300 FROM tiger_data.county_all"

  if [[ $(query "SELECT count(*) > 0 FROM api.load_log WHERE state = 'DC'" | tr -d '[:space:]') != "t" ]]; then
    skip "DC geocode (run: make load STATES=DC)"
    skip "DC reverse geocode"
    skip "coverage reporting"
  else
    expect_true "geocoding a known DC address lands in DC" \
      "SELECT count(*) = 1 AND max(state) = 'DC' AND max(rating) <= 20
       FROM api.geocode('1731 New Hampshire Avenue Northwest, Washington, DC 20010', 1)"

    expect_true "the geocoded point is inside the DC bounding box" \
      "SELECT bool_and(longitude BETWEEN -77.2 AND -76.9
                   AND latitude BETWEEN 38.7 AND 39.1)
       FROM api.geocode('1731 New Hampshire Avenue Northwest, Washington, DC 20010', 1)"

    # The parser needs no help with this input; the point is that bypassing
    # it lands on the same segment the text form does.
    expect_true "a structured geocode of the DC address matches the text form" \
      "WITH t AS (
         SELECT longitude, latitude
         FROM api.geocode('1731 New Hampshire Avenue Northwest, Washington, DC 20010', 1)
       ), p AS (
         SELECT *
         FROM api.geocode_parts('1731', 'New Hampshire', 'Ave', NULL, 'NW', 'Washington', 'DC', '20009', 1)
       )
       SELECT count(*) = 1 AND max(p.state) = 'DC' AND max(p.rating) <= 20
          AND bool_and(abs(p.longitude - t.longitude) < 0.0005
                   AND abs(p.latitude - t.latitude) < 0.0005)
       FROM p, t"

    # 20009 is a DC zip; the state says otherwise. Upstream trusts the state,
    # which with only DC loaded means no match at all -- the same path a
    # misparsed 'NE' or 'Co' takes on a full load, minus the wrong answer.
    expect_true "a zip that contradicts the parsed state wins" \
      "SELECT count(*) = 1 AND max(state) = 'DC'
       FROM api.geocode('1731 New Hampshire Ave NW, Washington, MD 20009', 1)"

    # Left unsplit, a zip+4 matches nothing in zip_state and the result takes
    # the zip penalty, so equal ratings show the split happened.
    expect_true "a nine-digit zip geocodes as well as its five-digit prefix" \
      "WITH five AS (
         SELECT rating
         FROM api.geocode_parts('1731', 'New Hampshire', 'Ave', NULL, 'NW', 'Washington', 'DC', '20009', 1)
       ), nine AS (
         SELECT rating
         FROM api.geocode_parts('1731', 'New Hampshire', 'Ave', NULL, 'NW', 'Washington', 'DC', '20009-1234', 1)
       )
       SELECT count(*) = 1 AND bool_and(five.rating = nine.rating)
       FROM five, nine"

    # The round trip is the real test of both functions: a wrong SRID or a
    # swapped lon/lat argument passes every check above and fails this one.
    expect_true "reverse geocoding that point returns the same street" \
      "WITH forward AS (
         SELECT longitude, latitude
         FROM api.geocode('1731 New Hampshire Avenue Northwest, Washington, DC 20010', 1)
       )
       SELECT count(*) > 0
       FROM forward, api.reverse_geocode(forward.longitude, forward.latitude, 1) AS r
       WHERE r.street ILIKE '%New Hampshire%'"

    expect_true "reverse geocode reports a sane distance" \
      "WITH forward AS (
         SELECT longitude, latitude
         FROM api.geocode('1731 New Hampshire Avenue Northwest, Washington, DC 20010', 1)
       )
       SELECT bool_and(r.distance_metres < 1000)
       FROM forward, api.reverse_geocode(forward.longitude, forward.latitude, 1) AS r"

    # The loader creates tables but not every index geocode() depends on, so a
    # skipped or failed index step leaves a working-but-unusably-slow geocoder.
    expect_true "no indexes are missing after the index step" \
      "SELECT coalesce(missing_indexes_generate_script(), '') = ''"

    # The load exiting 0 is not evidence of a complete load; this is.
    expect_true "DC passes completeness verification" \
      "SELECT api.state_is_complete('DC')"

    expect_true "no completeness check failed for DC" \
      "SELECT count(*) = 0 FROM api.verify_state('DC') WHERE ok IS FALSE"

    expect_true "every county-level layer covers every DC county" \
      "SELECT count(*) = 0 FROM api.verify_state('DC', deep => true)
       WHERE check_name = 'county_coverage' AND ok IS FALSE"

    # A verifier that cannot fail is worthless, so prove it fails. ZZ is not a
    # state, so this holds however many real ones are loaded; the original
    # used RI and broke the day all 56 were.
    expect_true "verification rejects a state that does not exist" \
      "SELECT NOT api.state_is_complete('ZZ')"

    expect_true "coverage reports DC" \
      "SELECT count(*) = 1 FROM api.coverage() WHERE state = 'DC' AND tiger_year = '2025'"
  fi
fi

printf '\n%d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
[[ $failed -eq 0 ]]
