#!/usr/bin/env bash
# Deterministic comparison: geocode the SAME fixed addresses with the before
# and after versions, then list every address whose outcome changed. No
# sampling noise: if lost and gained are both zero, the change cost nothing.
# ~2,000 addresses x 2 versions x ~100 ms, single session: about 7 minutes.
# usage: N=2000 bench/diff.sh [before.sql] [after.sql]
set -euo pipefail
N=${N:-2000}
before=${1:-bench/upstream.sql}
after=${2:-sql/30-performance-fixes.sql}
psql() { docker compose exec -T --user postgres db psql --no-psqlrc --quiet --set ON_ERROR_STOP=1 "$@"; }
[[ $(psql -At -c "SELECT tiger.get_geocode_setting('use_pagc_address_parser')") == true ]] && { echo "PAGC parser is enabled; revert it first"; exit 1; }

run() { # label sqlfile
	psql -f - < "$2" >/dev/null
	psql -c "DROP TABLE IF EXISTS bench.outcome_$1;
	         CREATE UNLOGGED TABLE bench.outcome_$1 AS
	         SELECT a.id, a.address, r.rating, r.formatted
	         FROM bench.addresses a
	         LEFT JOIN LATERAL (SELECT rating, formatted FROM api.geocode(a.address, 1)) r ON true
	         WHERE a.id <= $N;"
	echo "  $1: $(psql -At -c "SELECT count(*) FILTER (WHERE rating IS NOT NULL)||' of '||count(*)||' matched' FROM bench.outcome_$1")"
}
run before "$before"
run after  "$after"

echo "-- lost (matched before, not after) --"
psql -c "SELECT b.address, b.rating AS was_rating, b.formatted AS was
         FROM bench.outcome_before b JOIN bench.outcome_after a USING (id)
         WHERE b.rating IS NOT NULL AND a.rating IS NULL ORDER BY b.address"
echo "-- gained (not before, matched after) --"
psql -At -c "SELECT count(*) FROM bench.outcome_before b JOIN bench.outcome_after a USING (id) WHERE b.rating IS NULL AND a.rating IS NOT NULL" | sed 's/^/  /'
echo "-- matched by both, to a DIFFERENT result --"
psql -c "SELECT b.address, b.rating AS was, a.rating AS now, b.formatted AS was_result, a.formatted AS now_result
         FROM bench.outcome_before b JOIN bench.outcome_after a USING (id)
         WHERE b.rating IS NOT NULL AND a.rating IS NOT NULL AND b.formatted IS DISTINCT FROM a.formatted ORDER BY b.address LIMIT 20"
echo "($after is installed)"
