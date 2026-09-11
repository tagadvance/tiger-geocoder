#!/usr/bin/env bash
# Geocodes per second at increasing concurrency. Run from the repo root,
# after setup.sql has built bench.addresses once. Each block is one
# pgbench run; watch tps for the knee.
set -euo pipefail
psql() { docker compose exec -T --user postgres db psql --no-psqlrc --quiet --set ON_ERROR_STOP=1 "$@"; }

psql -f - <bench/harness.sql
# ids are dense from 1; the draw range must match or a share of iterations
# geocode NULL in microseconds and inflate every number.
nrows=$(psql --tuples-only --no-align -c "SELECT max(id) FROM bench.addresses" | tr -d '[:space:]')
echo "sampled addresses: $nrows"
docker compose cp bench/geocode.sql db:/tmp/geocode.sql >/dev/null

# A/B knobs: PGOPTIONS applies per-session settings to every pgbench connection
# without touching the server, e.g. PGOPTIONS='-c jit=off'. QUICK=1 runs only
# 1 and 16 clients for 30s each, for iterating.
opts=(); [[ -n ${PGOPTIONS:-} ]] && opts=(-e "PGOPTIONS=$PGOPTIONS")
if [[ ${QUICK:-0} == 1 ]]; then sweep=(1 16); secs=30; else sweep=(1 4 8 16 24 32); secs=60; fi
echo "settings: ${PGOPTIONS:-server defaults}"

echo "-- warm-up (fills shared_buffers; discard) --"
docker compose exec "${opts[@]}" --user postgres db pgbench -n -D nrows="$nrows" -c 16 -j 16 -T 20 -f /tmp/geocode.sql | grep -E '^tps'
for clients in "${sweep[@]}"; do
	echo "-- clients=$clients --"
	docker compose exec "${opts[@]}" --user postgres db pgbench -n -D nrows="$nrows" -c "$clients" -j "$(( clients < 16 ? clients : 16 ))" \
		-T "$secs" -f /tmp/geocode.sql | grep -E '^(tps|latency average)'
done

echo "-- geocoder errors during the run --"
psql -c "SELECT count(*) AS failures, count(DISTINCT error) AS distinct_errors FROM bench.failures"
psql -c "SELECT error, count(*), min(address) AS example FROM bench.failures GROUP BY error ORDER BY 2 DESC LIMIT 5"
