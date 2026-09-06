# tiger-geocoder

A US address geocoder and reverse geocoder in a Docker image: PostgreSQL,
PostGIS, and the `postgis_tiger_geocoder` extension, plus the tooling to load
Census TIGER/Line data into it without babysitting.

The geocoding itself is upstream's. What this repository adds is everything
around it: an image with the loader's dependencies actually present, loader
scripts hardened against the ways they silently half-succeed, and a small `api`
schema so callers bind to a stable contract instead of to PostGIS internals.

## Quick start

```sh
cp .env.example .env      # set POSTGRES_PASSWORD
make up                   # build and start; creates extensions and the api schema
make load STATES=DC       # nation layers, then DC, then indexes
make test
```

`make` on its own lists the targets.

A clean run to a working DC geocoder takes about half a minute. Larger states
take considerably longer, dominated by download time.

```
$ make psql
geocoder=# SELECT * FROM api.geocode('1731 New Hampshire Ave NW, Washington, DC', 1);
 rating |     longitude      |     latitude      | street_number |    street     | street_type |    city    | state |  zip
--------+--------------------+-------------------+---------------+---------------+-------------+------------+-------+-------
      2 | -77.03980839682588 | 38.91336487167728 | 1731          | New Hampshire | Ave         | Washington | DC    | 20009
```

## The api schema

Callers should use `api.*` rather than `tiger.geocode()` directly. The tiger
functions return composite types that most clients handle badly, their
signatures have moved between PostGIS releases, and they need `tiger` on the
caller's `search_path` to resolve at all. The `api` wrappers return flat rows,
pin their own `search_path`, and are the interface this project keeps stable.

| Function | Returns |
| --- | --- |
| `api.geocode(address text, max_results int = 1)` | `rating`, `longitude`, `latitude`, address parts, `formatted` |
| `api.reverse_geocode(longitude float8, latitude float8, max_results int = 1)` | `distance_metres`, address parts, `formatted` |
| `api.coverage()` | one row per state loaded, with TIGER vintage and load time |

Coordinates are WGS84 (EPSG:4326). TIGER itself is NAD83 (EPSG:4269); the
wrappers transform explicitly so the contract names one datum rather than
implying two.

`rating` is upstream's match confidence, where **lower is better** and 0 is an
exact match.

## Loading data

`tiger-load` runs inside the container and takes a subcommand:

```sh
make nation                    # national county and state layers; required first
make load STATES="OH KY"       # nation, then those states, then indexes
make index                     # install missing indexes and vacuum analyze
```

Three things about this are worth knowing, because each one is a way the
upstream loader fails quietly:

- **The generated scripts have no error handling.** Upstream tells you to add
  `set -e -u` by hand. `tiger-load` does that, and adds `shopt -s nullglob`,
  without which the scripts' `for z in *.zip` loops run `unzip` on a literal
  glob whenever a state has no file for a layer — a routine case that would
  otherwise abort the entire load.
- **Downloads are serial.** `tiger-prefetch` extracts the script's own wget
  lines and runs them in parallel first; the real pass then finds the files
  cached. Tune with `TIGER_DOWNLOAD_JOBS`.
- **The index step is not optional.** The loader creates tables but not every
  index the geocode functions rely on. Skip `make index` and you get a geocoder
  that works and is unusably slow.

Data volume is not modest. DC alone is ~100 MB of downloads; a national load is
in the hundreds of gigabytes once indexed. Load only the states you need.

## Moving a loaded database

`./data` and `./gisdata` are bind mounts, not named volumes, specifically so a
loaded database is an ordinary directory you can move:

```sh
make snapshot      # stops the database, tars ./data
rsync -a data/ homelab:/srv/tiger-geocoder/data/
```

The database must be stopped first. A tar of a live `PGDATA` is a torn copy, and
it will restore cleanly right up until it doesn't.

## Versions

| Component | Version | Note |
| --- | --- | --- |
| PostgreSQL | 18 | Loader requires 16+ |
| PostGIS | 3.6 | Last series to bundle the geocoder |
| postgis_tiger_geocoder | 2025.2 | Standalone release, built from source |
| TIGER/Line | 2025 | Matches the extension's default vintage |

`postgis_tiger_geocoder` was split out of PostGIS after 3.6 and is now released
on its own cadence, versioned by the TIGER vintage it targets; PostGIS 3.7 will
not ship it. The image therefore builds it from source rather than inheriting
whatever the base image happens to bundle.

Two operational notes:

- **PostgreSQL 18 images mount `/var/lib/postgresql`, not `.../data`.** The
  server keeps its cluster in a major-version subdirectory, which is what lets a
  future `pg_upgrade --link` run without crossing a mount boundary. Mounting the
  old path is a hard error.
- **A bind-mounted cluster is pinned to its major version.** Moving to PG19
  later means `pg_upgrade` or a dump and reload, which on a national dataset is
  not a quick job.

The compose file starts Postgres with `synchronous_commit=off` and a large
`max_wal_size`, which suits a bulk load of re-downloadable data. Reconsider
those before treating the result as a system of record.

## Licence

Apache License 2.0; see `LICENSE` and `NOTICE`.

The image bundles PostGIS and `postgis_tiger_geocoder`, which are GPLv2, and
loads TIGER/Line data, which is a public-domain work of the US Census Bureau.
Apache-2.0 covers this repository's own contents.
