-- A loader profile for running the generated scripts inside this container.
--
-- Upstream's advice is to copy the stock `sh` profile rather than edit it, so an
-- extension upgrade cannot silently clobber these paths. Only declare_sect
-- differs; every other column is inherited verbatim.
--
-- ${staging_fold} is substituted by tiger.loader_macro_replace at generation
-- time. ${PGBIN}, ${PGHOST} and friends are not names it knows, so they survive
-- into the script and are expanded by bash at run time -- which is what lets one
-- profile serve any database name without being rebuilt.
INSERT INTO tiger.loader_platform
	(os, declare_sect, pgbin, wget, unzip_command, psql, path_sep, loader,
	 environ_set_command, county_process_command)
SELECT
	'docker',
	$declare$TMPDIR="${staging_fold}/temp/"
UNZIPTOOL=unzip
WGETTOOL="$(command -v wget)"
export PGBIN="$(pg_config --bindir)"
export PGHOST="${PGHOST:-/var/run/postgresql}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
export PGDATABASE="${PGDATABASE:-geocoder}"
# shp2pgsql ships with PostGIS and lands in /usr/bin, not in pg_config
# --bindir, so resolve both through PATH rather than assuming they share a home.
PSQL="$(command -v psql)"
SHP2PGSQL="$(command -v shp2pgsql)"
cd ${staging_fold}
$declare$,
	pgbin, wget, unzip_command, psql, path_sep, loader,
	environ_set_command, county_process_command
FROM tiger.loader_platform
WHERE os = 'sh'
ON CONFLICT (os) DO UPDATE SET
	declare_sect = EXCLUDED.declare_sect,
	pgbin = EXCLUDED.pgbin,
	wget = EXCLUDED.wget,
	unzip_command = EXCLUDED.unzip_command,
	psql = EXCLUDED.psql,
	path_sep = EXCLUDED.path_sep,
	loader = EXCLUDED.loader,
	environ_set_command = EXCLUDED.environ_set_command,
	county_process_command = EXCLUDED.county_process_command;
