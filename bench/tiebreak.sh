#!/usr/bin/env bash
# Are the outcomes diff.sh reported as changed a logic difference, or
# tie-breaking that follows the plan? Upstream cuts candidates with
# ORDER BY rank LIMIT max_results*3 (and two more bounded ORDER BYs) before the
# final rating, and nothing breaks ties in rank, so which candidates survive
# depends on the order rows come off disk, which depends on the plan. Geocode
# the changed addresses under each version with the planner nudged two ways.
# If results move with the plan under the BEFORE version too, the change only
# reordered ties. Run after diff.sh.
# usage: bench/tiebreak.sh [before.sql] [after.sql]
set -euo pipefail
declare -A file=([before]="${1:-bench/upstream.sql}" [after]="${2:-sql/30-performance-fixes.sql}")
psql() { docker compose exec -T --user postgres db psql --no-psqlrc --quiet --set ON_ERROR_STOP=1 "$@"; }
[[ $(psql -At -c "SELECT tiger.get_geocode_setting('use_pagc_address_parser')") == true ]] && { echo "PAGC parser is enabled; revert it first"; exit 1; }

changed="SELECT b.address FROM bench.outcome_before b JOIN bench.outcome_after a USING (id)
         WHERE b.formatted IS DISTINCT FROM a.formatted"

run() { # label plan-label settings
	psql -At -F' | ' -c "$3
		SELECT v.address, '$1', '$2', r.rating, r.formatted
		FROM ($changed) v
		LEFT JOIN LATERAL (SELECT rating, formatted FROM api.geocode(v.address, 1)) r ON true"
}
for v in before after; do
	psql -f - < "${file[$v]}" >/dev/null
	run "$v" default ""
	run "$v" nohash  "SET enable_hashjoin = off; SET enable_mergejoin = off;"
	run "$v" noseq   "SET enable_seqscan = off;"
done | sort -t'|' -k1,1 -k2,2 -k3,3
echo "(${file[after]} is installed)"
