# tiger-geocoder

A US address geocoder and reverse geocoder in a Docker image: PostgreSQL 18,
PostGIS 3.6, and `postgis_tiger_geocoder` 2025.2, plus the tooling to load
Census TIGER/Line 2025 data into it without babysitting.

The geocoding itself is upstream's. What this repository adds is everything
around it: an image with the loader's dependencies actually present, loader
scripts hardened against the ways they silently half-succeed, and a small `api`
schema so callers bind to a stable contract instead of to PostGIS internals.

## How it works

The Census publishes TIGER/Line as thousands of zip files — one per county for
the address, street and face layers. `tiger-load` generates the loader scripts,
fetches and checksums every file, runs the load, builds the indexes the geocoder
needs, and then asserts against the loaded data that the state is actually
complete before recording it.

## Quick start

```sh
cp .env.example .env      # set POSTGRES_PASSWORD
make up                   # build and start; creates extensions and the api schema
make load STATES="AK AL AR AS AZ CA CO CT DC DE FL GA GU HI IA ID IL IN KS KY \
  LA MA MD ME MI MN MO MP MS MT NC ND NE NH NJ NM NV NY OH OK OR PA PR RI SC \
  SD TN TX UT VA VI VT WA WI WV WY"
make test
```

That is the complete set — 50 states, DC, and five territories. **Trim it to
what you need**; a single state is `make load STATES=OH`, and states are loaded
independently, so a shorter list is a smaller and faster load in every respect.

Loading everything takes about a day and ends at a 30 GB download cache and
a 96 GB database, indexed. A single small state is minutes. `make` on its own lists the targets.

## Querying it

Two schemas matter. **`tiger`** is created by the PostGIS geocoder extension and
holds its tables and functions — it is upstream's, and it changes when upstream
changes. **`api`** is this project's: a handful of thin wrappers over those
functions, and the interface intended for callers.

Use `api.*` rather than `tiger.geocode()` directly. The tiger functions return
composite types that most clients handle badly, their signatures have moved
between PostGIS releases, and they need `tiger` on the caller's `search_path` to
resolve at all. The `api` wrappers return flat rows, pin their own
`search_path`, and are what this project keeps stable.

```
$ make psql
geocoder=# SELECT * FROM api.geocode('1731 New Hampshire Ave NW, Washington, DC', 1);
 rating |     longitude      |     latitude      | street_number |    street     | street_type |    city    | state |  zip
--------+--------------------+-------------------+---------------+---------------+-------------+------------+-------+-------
      2 | -77.03980839682588 | 38.91336487167728 | 1731          | New Hampshire | Ave         | Washington | DC    | 20009
```

| Function | Returns |
| --- | --- |
| `api.geocode(address text, max_results int = 1)` | `rating`, `longitude`, `latitude`, address parts, `formatted` |
| `api.geocode_parts(house_number, street_name, street_suffix, pre_direction, post_direction, city_name, state_code, zip_code text, max_results int = 1)` | as `api.geocode` |
| `api.reverse_geocode(longitude float8, latitude float8, max_results int = 1)` | `distance_metres`, address parts, `formatted` |
| `api.coverage()` | one row per state loaded, with TIGER vintage and load time |

`api.geocode_parts` takes the address already split into components and
bypasses the free-text parser; use it whenever you hold the components, because
on input without a city (`600 N Sheridan St, 61832`) the parser misassigns the
trailing tokens — street `N`, city `Sheridan St` — on about a quarter of
inputs. Everything after `street_name` is optional, `street_suffix` is the
abbreviated type TIGER stores (`St`, `Ave`), and `zip_code` may be five or nine
digits. The text form trusts the zip over a parsed state: the parser reads
any trailing two-letter token as one (`1701 21st Rd NE, 66871` became
Nebraska), and upstream would return a confident match from the wrong state.

Coordinates come back as **WGS84** (EPSG:4326) — the ordinary latitude and
longitude that GPS, web maps and GeoJSON use, so they can be handed straight to
a mapping library. TIGER stores its geometry in NAD83 (EPSG:4269), a different
reference frame that puts the same place at slightly different numbers. The
wrappers transform explicitly, so the contract names one datum instead of
quietly implying two.

`rating` is upstream's match confidence, where **lower is better** and 0 is an
exact match.

The database listens on `${POSTGRES_PORT:-5432}`, so any PostgreSQL client works
the same way.

## Versions

| Component | Version | Note |
| --- | --- | --- |
| PostgreSQL | 18 | Loader requires 16+ |
| PostGIS | 3.6 | Last series to bundle the geocoder |
| `postgis_tiger_geocoder` | 2025.2 | Standalone release, built from source |
| TIGER/Line | 2025 | Matches the extension's default vintage |

These are chosen to work together, and two of the couplings are not obvious:

- **The extension version picks the data vintage.**
  `postgis_tiger_geocoder` is versioned by the TIGER year it targets, so 2025.2
  expects TIGER/Line 2025. Pointing it at a different vintage is not a supported
  combination.
- **PostGIS 3.6 is the last series to bundle the geocoder.** It was split out
  afterwards and is now released on its own cadence; 3.7 does not ship it. The
  image therefore builds it from source rather than inheriting whatever the base
  image happens to bundle.

## Documentation

| | |
| --- | --- |
| [SETUP.md](SETUP.md) | Loading data and verifying a load |
| [TUNING.md](TUNING.md) | Why the defaults are wrong, what tiger-tune does, overriding it |
| [BACKUP.md](BACKUP.md) | Moving a loaded database to another host |

## Licence

Apache License 2.0; see `LICENSE` and `NOTICE`.

The image bundles PostGIS and `postgis_tiger_geocoder`, which are GPLv2, and
loads TIGER/Line data, which is a public-domain work of the US Census Bureau.
Apache-2.0 covers this repository's own contents.
