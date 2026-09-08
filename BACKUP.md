# Backup and migration

Moving a loaded database to another host. See [SETUP.md](SETUP.md) for building
one from scratch.

**Prefer copying what you already have to downloading it again.** The Census
serves TIGER/Line for free and rate-limits accordingly; every re-download is a
cost borne by them and by everyone else fetching it. If the data already exists
on a machine you control, move it rather than asking for a second copy.

That applies to `./gisdata` at least as much as to `./data` — the download cache
is the part that was expensive to acquire, and copying it to a second host lets
that host build its own database without touching the Census at all.

## Snapshot and restore

`./data` and `./gisdata` are bind mounts, not named volumes, specifically so a
loaded database is an ordinary directory you can move.

```sh
make snapshot                                   # stops the db, tars ./data
scp tiger-geocoder-*.tar.zst host:/srv/
ssh host 'cd /srv && sudo tar --extract --zstd --numeric-owner \
  --file tiger-geocoder-*.tar.zst'
```

Two things that are not optional:

- **The database must be stopped.** A tar of a live `PGDATA` is a torn copy, and
  it will restore cleanly right up until it doesn't. `make snapshot` depends on
  `down` for this reason.
- **`--numeric-owner` on extraction.** The cluster must keep the container's
  uid rather than being remapped to whoever holds that name on the far host.
  Extraction needs root for the same reason.

## Why not rsync

The cluster is mode 700 owned by uid 999, so your login account cannot read it.
`sudo rsync` does not fix it either: sudo makes rsync run ssh as *root*, which
has no key for the far host, and even connected, the receiving rsync cannot set
uid 999 without root there too. Making it work needs privilege on both ends and
passwordless sudo for rsync on the far side. The snapshot route avoids all of
it, which is why it is the one documented.

## Upgrading PostgreSQL

A bind-mounted cluster is pinned to its major version. The image is PostgreSQL
18; moving to 19 later means `pg_upgrade` or a dump and reload, which on a large
load is not a quick job. Rebuilding from `./gisdata` is often the simpler route,
since the download cache is the expensive half.

## Do not chown the data directory

**Do not `chown ./data` to your own user to work around the permissions.**
PostgreSQL refuses to start on a cluster it does not own, and a *running* server
fails every new connection with `could not open file "global/pg_filenode.map":
Permission denied` — which looks intermittent rather than fatal. If it happens,
`docker compose restart db` repairs it.
