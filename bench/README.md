# Benchmark

Throughput and fidelity of `api.geocode` against the loaded data, and the
before/after evidence for each change carried in `sql/30-performance-fixes.sql`.

## Run

From the repo root, against the running container. `setup.sql` once: it samples
~45,000 real addresses (house number, street, zip, no city) from `tiger.addr`,
so every one exists and a miss is the geocoder's doing.

```sh
docker compose exec -T --user postgres db psql -f - < bench/setup.sql
bench/run.sh          # tps at 1..32 clients; QUICK=1 does 1 and 16
bench/ab.sh           # before vs after, same session: tps, no-match, p99, max
bench/diff.sh         # the same 2,000 addresses through both: lost, gained, changed
bench/tiebreak.sh     # the changed ones, under three plans each
```

`ab.sh`, `diff.sh` and `tiebreak.sh` install `bench/upstream.sql` (the helpers
and `geocode_address` as postgis_tiger_geocoder 2025.2 ships them), measure,
then install `sql/30-performance-fixes.sql` and measure again, so the repo's
version is always what they leave behind. Both take `before.sql after.sql` to
compare anything else.

Planning time needs `pg_stat_statements` preloaded, which costs about half the
throughput while it is on, so never compare a run with it to one without:

```sh
docker compose -f compose.yaml -f bench/compose.pgss.yaml up --detach --wait
docker compose exec --user postgres db psql -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements" -c "SELECT pg_stat_statements_reset()"
PGOPTIONS='-c pg_stat_statements.track=all -c pg_stat_statements.track_planning=on' QUICK=1 bench/run.sh
docker compose exec -T --user postgres db psql -f - < bench/pgss-report.sql
docker compose up --detach --wait
```

`timings-report.sql` gives latency percentiles and the slowest addresses of the
last run. Everything lives in the `bench` schema; drop it when done.

## Results

Full 56-state TIGER 2025 load, PostgreSQL 18, 16 cores. `tps` is at 16 clients.
The fidelity check is `diff.sh`: the same 2,000 sampled addresses through both
versions, counting those that matched before and not after (lost) and the
reverse (gained). A change is only kept when both are zero.

### Helpers made inlinable: `least_hn`, `greatest_hn`, `diff_zip`

| | upstream | inlinable |
| --- | --- | --- |
| nested statements per geocode | 5,993 | 45 |
| tps | 103 | 129 |

Three function bodies, same contracts, spot-checked on the boundary values.
Covered by the combined diff below.

### Fallback: no soundex match for a numbered street

`soundex()` of a number is an empty string, so a numbered street matched
every numbered street in the state. Measured with `pg_stat_statements` on.

| | before | after |
| --- | --- | --- |
| tps | 116 | 132 |
| p99 | 464 ms | 421 ms |
| slowest address | 10.2 s | 3.2 s |
| `diff.sh` lost / gained | 0 / 0 | |

### State child tables named in the dynamic SQL

Every query in `geocode_address` selected from the `tiger.*` parents, so the
planner opened and locked all 56 states' children before excluding 55, on every
call, because `EXECUTE` never caches a plan. Measured upstream against the
whole of `sql/30-performance-fixes.sql`, so this row includes the fallback fix
above; the planning, lock and single-client rows are this change alone.

| | upstream | sql/30 |
| --- | --- | --- |
| tps | 117 | 223 |
| p99 | 431 ms | 327 ms |
| single-client latency | 96 ms | 53 ms |
| planning per geocode | 66 ms | 23 ms |
| locks held by one geocode | 2,886 | 192 |
| pgbench no-match | 2.4% | 2.4% |
| `diff.sh` matched | 1,956 / 2,000 | 1,956 / 2,000 |
| `diff.sh` lost / gained | 0 / 0 | |

Nine of the 1,956 matched a different segment, three at the same rating.
`tiebreak.sh` shows upstream doing the same on its own when only the plan
changes: with sequential scans disabled it moves two of them, one across three
ratings. Its candidate cuts (`ORDER BY rank LIMIT max_results*3` and two more)
have no tie-breaker, so equal candidates survive in disk order. That is
upstream's to fix, and the reason lost and gained, not changed, are the test.
