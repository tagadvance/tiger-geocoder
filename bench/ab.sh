#!/usr/bin/env bash
# Controlled A/B: the before version, then the after, same session, same
# sample, back to back. Prints the numbers that decide it side by side.
# usage: bench/ab.sh [before.sql] [after.sql]
set -euo pipefail
before=${1:-bench/upstream.sql}
after=${2:-sql/30-performance-fixes.sql}
psql() { docker compose exec -T --user postgres db psql --no-psqlrc --quiet --set ON_ERROR_STOP=1 "$@"; }
[[ $(psql -At -c "SELECT tiger.get_geocode_setting('use_pagc_address_parser')") == true ]] && { echo "PAGC parser is enabled; revert it first"; exit 1; }

measure() { # label sqlfile
	psql -f - < "$2" >/dev/null
	QUICK=1 bench/run.sh 2>/dev/null | grep -E '^tps' | tail -1 | sed "s/^/  $1  16-client /"
	psql -At -c "SELECT '  $1  no_match '||count(*) FILTER (WHERE hits=0)||' of '||count(*)||' ('||round(100.0*count(*) FILTER (WHERE hits=0)/count(*),1)||'%)  p99 '||round(percentile_cont(0.99) WITHIN GROUP (ORDER BY ms)::numeric)||' ms  max '||round(max(ms)::numeric)||' ms' FROM bench.timings"
}
measure before "$before"
measure after  "$after"
echo "($after is installed)"
