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
- **Downloads are unverified and unpaced.** The generated scripts fetch
  straight to the final filename, so an interrupted transfer is
  indistinguishable from a finished one, and nothing backs off when the Census
  rate-limits. `tiger-prefetch` runs the same wget lines first — one at a time,
  with a pause between them — tests each archive against the Census's own CRCs
  before marking it complete, and stops cleanly on a 429. Pace it with
  `TIGER_DOWNLOAD_WAIT`.
- **A load exiting 0 does not mean it loaded everything.** `nullglob` stops a
  missing file from aborting the run, which necessarily turns it into a silent
  skip; and county-level layers (`faces`, `featnames`, `edges`, `addr`) are
  fetched one file per county, so a large state can lose a dozen counties and
  look entirely healthy. Completeness is therefore asserted against the data, not
  the exit code — see below.
- **The index step is not optional.** The loader creates tables but not every
  index the geocode functions rely on. Skip `make index` and you get a geocoder
  that works and is unusably slow.

Data volume is not modest. DC alone is ~100 MB of downloads; a national load is
in the hundreds of gigabytes once indexed. Load only the states you need.

## Verifying a load

`make load` verifies each state before recording it, and refuses to record one
that fails: an unverified state stays absent from `api.load_log`, so re-running
drops its tables and loads it again. You can also check at any time:

```sh
make verify                        # every state the load log claims to hold
make verify STATES=OH              # one state
make verify VERIFY_DEEP=true       # slower, exact; see below
```

Each layer gets three checks: the table exists, it holds rows, and it covers
every county the nation load says the state has. A missing layer or a partial
county set fails the state.

```
 layer  |   check_name    | ok |      detail
--------+-----------------+----+-------------------
 faces  | table_exists    | t  |
 faces  | not_empty       | t  | 8638 rows
 faces  | county_coverage | t  | 1 of 1 counties
```

`ok` of `NULL` means **not checked**, which is deliberately not the same as
passing. `featnames` and `addr` carry no `countyfp`, so their county coverage
cannot be checked cheaply; `VERIFY_DEEP=true` recovers it by joining `tlid` to
`edges`, at the cost of a join between two of the largest tables in the schema.
`place` has no county dimension at all and stays unchecked either way.

## Tuning

Server settings are computed at startup by `docker/bin/tiger-tune`, from the
memory and cores the *container* can see, and injected by the entrypoint. There
are no megabyte counts pinned in `compose.yaml`: a number large enough for a
16-core server stops a laptop from starting, and one small enough for the laptop
wastes the server. Stock PostgreSQL defaults are worse than either -- 128 MB of
`shared_buffers` and `random_page_cost=4` on a machine with 64 GB and an SSD.

What was applied is logged on every start:

```sh
docker compose logs db | grep tiger-tune
```

### The formulas

| Setting | Value | Why |
| --- | --- | --- |
| `shared_buffers` | ¼ of memory | The conventional split; the rest of RAM still caches for the database via the kernel |
| `effective_cache_size` | ¾ of memory | Planner hint only, allocates nothing. Too low is how `geocode()` starts sequentially scanning a national `featnames` |
| `work_mem` | memory ÷ 1024, 4–256 MB | Per sort or hash node, per worker, so the ceiling matters more than the ratio |
| `maintenance_work_mem` | memory ÷ 16, ≤ 8 GB | Index builds, which is where a national load spends its tail |
| `autovacuum_work_mem` | ¼ of the above, ≤ 2 GB | See below -- this one is not optional |
| `max_worker_processes`, `max_parallel_workers` | physical cores | SMT siblings share execution units; counting them inflates the pools past what the box can run |
| `max_parallel_workers_per_gather`, `max_parallel_maintenance_workers` | half the cores | So one query or index build cannot monopolise the machine |
| `random_page_cost` | 1.1 | Assumes an SSD. On spinning disks set `TIGER_TUNE_RANDOM_PAGE_COST=4` |
| `effective_io_concurrency`, `maintenance_io_concurrency` | 64 | The default of 16 is priced for a single spindle; these feed the bitmap heap scans `geocode()` leans on |
| `default_statistics_target` | 200 | Costs a slower `ANALYZE` once at the end of the load, and buys better plans against tables that never change again |

Memory and core detection both respect cgroup limits rather than reading the
host. `/proc/meminfo` is not namespaced, so a memory-capped container reads the
whole machine's RAM, sizes `shared_buffers` past its own cap, and gets
OOM-killed under load instead of failing at startup where you would notice.

**`autovacuum_work_mem` must be set whenever `maintenance_work_mem` is raised.**
It defaults to `-1`, meaning "inherit `maintenance_work_mem`" -- and each
autovacuum worker claims that independently, so raising `maintenance_work_mem`
to 4 GB silently authorises three times that in the background. A test asserts
the cap is in place.

### Profiles

`TIGER_TUNE_PROFILE` selects one of two, and the table above applies to both:

- **`load`** (default) adds `synchronous_commit=off`, `wal_compression=zstd`, a
  large `max_wal_size`, a 30-minute checkpoint timeout, and disables the
  autovacuum cost delay. This trades crash safety for write throughput, which is
  the right trade while loading: a crash means re-running the load, and loads are
  re-runnable by design.
- **`serve`** emits the durable settings only. Switch to it once the data is in
  and the database is a system of record.

### Written once, read forever

The workload is lopsided: a long bulk load, then a database that is essentially
read-only. Three things follow from that, and they are already applied.

`tiger-load index` finishes with `VACUUM (FREEZE, ANALYZE)` rather than a plain
`VACUUM ANALYZE`. Freezing now converts a future anti-wraparound autovacuum --
which would eventually rewrite hundreds of gigabytes at a moment nobody chose --
into work done at the end of the load, where it is expected. It also marks pages
all-visible, which is the precondition for index-only scans.

`default_statistics_target` and the IO concurrency settings above are priced for
reads for the same reason. The usual argument against a higher statistics target
is that churn invalidates the extra work; there is no churn here.

Autovacuum is left enabled but will rarely have anything to do. That is fine --
the cost of leaving it on is nil, and it still handles the occasional
incremental state load.

If restart latency ever matters, `pg_prewarm` would let a warm `shared_buffers`
survive a restart instead of being refilled by live queries. Not set up, since
the database is not expected to restart often.

`full_page_writes=off` would speed the load further but is deliberately not
included. It is a different class of risk from `synchronous_commit=off`: losing
recent transactions means reloading one state, whereas torn pages mean a corrupt
cluster and redoing the entire load.

### Overriding

Set `TIGER_TUNE=false` to skip tuning and run on stock defaults. To override a
single setting, pass it as a command -- the entrypoint puts the computed flags
first, and PostgreSQL applies the last `-c` for a setting:

```yaml
command: [postgres, -c, shared_buffers=24GB]
```

`TIGER_TUNE_MEM_MIB` and `TIGER_TUNE_CORES` override detection itself, which is
also how to see what another machine would get:

```sh
docker compose exec --user postgres -e TIGER_TUNE_CORES=4 db tiger-tune
```

Note that `TIGER_DOWNLOAD_WAIT` is not part of this. It paces the Census
download pre-warm, which is bound by the network rather than the machine.
Downloads run one at a time and there is deliberately no knob to make them
concurrent: the FTP mirror caps per-client bandwidth, so extra workers measured
no faster than one, and over https concurrency is precisely what trips
Cloudflare's limiter.

## Moving a loaded database

`./data` and `./gisdata` are bind mounts, not named volumes, specifically so a
loaded database is an ordinary directory you can move:

First, be sure you actually need to. A state load is reproducible from the
Census in minutes; only a large multi-state load is worth moving. To set up a
second host, clone the repo and load there — do not copy `data/` or `gisdata/`.

```sh
make snapshot                                   # stops the db, tars ./data
scp tiger-geocoder-*.tar.zst host:/srv/
ssh host 'cd /srv && sudo tar --extract --zstd --numeric-owner \
  --file tiger-geocoder-*.tar.zst'
```

`--numeric-owner` on extraction is what keeps the cluster owned by the
container's uid instead of being remapped to whoever holds that name on the far
host. Extraction needs root for the same reason.

Plain `rsync` fails on this directory: the cluster is mode 700 owned by uid 999,
so your login account cannot read it. `sudo rsync` does not fix it either —
sudo makes rsync run ssh as *root*, which has no key for the far host, and even
connected, the receiving rsync cannot set uid 999 without root there too. If you
want rsync anyway, both ends need privilege and it looks like this:

```sh
sudo rsync -a --numeric-ids \
  -e 'ssh -i /home/tag/.ssh/id_ed25519 -o UserKnownHostsFile=/home/tag/.ssh/known_hosts' \
  --rsync-path='sudo rsync' \
  data/ tag@host:/srv/tiger-geocoder/data/
```

which additionally needs passwordless sudo for rsync on the far side. The
snapshot route above avoids all of it, which is why it is the one documented
first.

The database must be stopped first. A tar of a live `PGDATA` is a torn copy, and
it will restore cleanly right up until it doesn't.

The cluster is owned by the container's `postgres` user and is mode 700, so your
login account cannot read it — `make snapshot` borrows a container to do the tar
and hands the tarball back. For the same reason, rsync needs `--numeric-ids`, so
the cluster keeps its uid instead of being remapped to whoever happens to share
that name on the far end. **Do not `chown` the data directory to your own user
to work around this**: PostgreSQL refuses to start on a cluster it does not own,
and a running server fails every new connection with `could not open file
"global/pg_filenode.map": Permission denied`. If that happens,
`docker compose restart db` repairs it.

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
