#!/usr/bin/env bash
# Runs once, on an empty PGDATA, via the postgres image's entrypoint.
# Installs the extensions and the api schema. It deliberately loads no data:
# a national TIGER load runs for hours and belongs behind an explicit command,
# not inside a container's first boot.
set -euo pipefail

psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --set ON_ERROR_STOP=1 --no-psqlrc <<-'SQL'
	CREATE EXTENSION IF NOT EXISTS postgis;
	CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
	CREATE EXTENSION IF NOT EXISTS postgis_tiger_geocoder CASCADE;
	CREATE EXTENSION IF NOT EXISTS address_standardizer;
SQL

# As of the standalone releases the extension no longer puts itself on the
# search_path, and its functions resolve tiger tables unqualified. Without this
# every geocode() call fails with "relation does not exist".
psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --set ON_ERROR_STOP=1 --no-psqlrc \
  --command "ALTER DATABASE \"$POSTGRES_DB\" SET search_path = \"\$user\", public, tiger;"

for script in /usr/local/share/tiger-geocoder/*.sql; do
  psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    --set ON_ERROR_STOP=1 --no-psqlrc --file "$script"
done
