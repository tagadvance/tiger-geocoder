# Setup

Loading TIGER/Line data, verifying it landed, and the versions involved.
See [README.md](README.md) for what this is and how to query it,
[TUNING.md](TUNING.md) for server settings, and [BACKUP.md](BACKUP.md) for
moving a loaded database between hosts.

## First run

```sh
cp .env.example .env      # set POSTGRES_PASSWORD
make up                   # build and start; creates extensions and the api schema
make test                 # structural checks pass on an empty database
```

`make` on its own lists the targets.

Two directories appear alongside the repo and hold everything: `./data` is the
database itself, `./gisdata` is the Census download cache. Both are bind mounts
rather than named volumes, so they are ordinary directories you can inspect,
copy, or move — see [BACKUP.md](BACKUP.md).

## Updating the schema

The SQL under `sql/` — the `api` schema, the loader profile, the verifier — is
applied once by `initdb`, on an empty `./data`, and never again. When a change
to it lands after that, an existing database does not pick it up on `make up`.
Re-apply it by hand:

```sh
make build && make up     # the files come from the image
make schema
```

Everything under `sql/` is written to be re-applied safely (`IF NOT EXISTS`,
`OR REPLACE`, `ON CONFLICT`), so this is harmless to run at any time.

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
  before marking it complete, and stops cleanly on a 429.
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
