# Tuning

How the server sizes itself, and how to override it. See
[README.md](README.md) for what this is, and [SETUP.md](SETUP.md) for loading
data.

## Stock PostgreSQL defaults are wrong for this

They are sized to start anywhere, including a machine with 256 MB of RAM, so
they assume nothing about the hardware and leave everything on the table.
`shared_buffers` is 128 MB whether the box has 1 GB or 512 GB.
`random_page_cost` is 4, a figure priced for a spinning disk, which tells the
planner to avoid the index scans `geocode()` depends on. `effective_cache_size`
is 4 GB, so the planner believes almost nothing is cached and starts
sequentially scanning a national `featnames`.

Pinning better numbers in `compose.yaml` does not fix it either: a value large
enough for a 16-core server stops a laptop from starting, and one small enough
for the laptop wastes the server.

## What tiger-tune does

`docker/bin/tiger-tune` computes the settings at startup from the memory and
cores the *container* can actually see, and the entrypoint injects them. Nothing
is pinned in `compose.yaml`, so the same file is correct on a laptop and on a
64 GB server.

What was applied is logged on every start:

```sh
docker compose logs db | grep tiger-tune
```

## It already assumes the machine is yours

`shared_buffers` takes a quarter of memory and `effective_cache_size` claims the
other three quarters as kernel cache. Together they account for the whole
machine, so **the defaults are the dedicated-server configuration** — there is
no separate mode to switch on, and raising `shared_buffers` past a quarter
generally does not help, since the rest of RAM is still caching for the database
through the kernel.

The case that needs intervention is the opposite one: a machine shared with
something else. Tell it how much it may have, rather than letting it size for
the whole box:

```yaml
environment:
  TIGER_TUNE_MEM_MIB: "16384"   # behave as if the machine had 16 GB
  TIGER_TUNE_CORES: "4"
```

Container memory and CPU limits are already respected — detection reads cgroup
limits, not the host — so this is only needed when the constraint is a
convention rather than a limit.

## The formulas

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

## Profiles

`TIGER_TUNE_PROFILE` selects one of two, and the table above applies to both:

- **`load`** (default) adds `synchronous_commit=off`, `wal_compression=zstd`, a
  large `max_wal_size`, a 30-minute checkpoint timeout, and disables the
  autovacuum cost delay. This trades crash safety for write throughput, which is
  the right trade while loading: a crash means re-running the load, and loads are
  re-runnable by design.
- **`serve`** emits the durable settings only. Switch to it once the data is in
  and the database is a system of record.

## Written once, read forever

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

## Overriding

Set `TIGER_TUNE=false` to skip tuning and run on stock defaults. To override a
single setting, pass it as a command -- the entrypoint puts the computed flags
first, and PostgreSQL applies the last `-c` for a setting:

```yaml
command: [postgres, -c, shared_buffers=24GB]
```

The same `TIGER_TUNE_MEM_MIB` and `TIGER_TUNE_CORES` used above to cap a shared
machine are also how to preview what another one would get, without going there:

```sh
docker compose exec --user postgres -e TIGER_TUNE_CORES=4 db tiger-tune
```

Downloads are not part of this, and have no settings at all: one request at a
time, one second apart, from either mirror. The FTP mirror caps per-client
bandwidth, so extra workers measured no faster than one; over https, concurrency
and haste are precisely what trip Cloudflare's limiter. The only download choice
is which mirror, via `WEBSITE_ROOT`.
