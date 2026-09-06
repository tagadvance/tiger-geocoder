# syntax=docker/dockerfile:1

# postgis_tiger_geocoder was split out of PostGIS core after the 3.6 series and
# is now released on its own cadence, versioned by the TIGER vintage it targets.
# Build it from source rather than inheriting whatever the base image bundles:
# PostGIS 3.7 will not ship it at all.
ARG PG_MAJOR=18
ARG POSTGIS_MAJOR=3.6
ARG TIGER_GEOCODER_VERSION=2025.2

FROM postgis/postgis:${PG_MAJOR}-${POSTGIS_MAJOR} AS extension

ARG PG_MAJOR
ARG TIGER_GEOCODER_VERSION
ARG TIGER_GEOCODER_MD5=19b408f8b7369a4782e875c7f497f8e0

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# The extension is pure PL/pgSQL, so this stage compiles nothing; it only needs
# PGXS and perl to assemble and install the SQL.
RUN apt-get update \
	&& apt-get install --yes --no-install-recommends \
		build-essential ca-certificates curl perl postgresql-server-dev-${PG_MAJOR} \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN tarball="postgis_tiger_geocoder-${TIGER_GEOCODER_VERSION}.tar.gz" \
	&& curl --fail --silent --show-error --location --remote-name \
		"https://download.osgeo.org/postgis/source/postgis_tiger_geocoder/${tarball}" \
	&& echo "${TIGER_GEOCODER_MD5}  ${tarball}" | md5sum --check --strict \
	&& tar --extract --gzip --file "${tarball}" \
	&& make --directory postgis_tiger_geocoder \
	&& make --directory postgis_tiger_geocoder install


FROM postgis/postgis:${PG_MAJOR}-${POSTGIS_MAJOR}

ARG PG_MAJOR
ARG TIGER_GEOCODER_VERSION

LABEL org.opencontainers.image.source="https://github.com/tagadvance/tiger-geocoder"
LABEL org.opencontainers.image.description="PostGIS TIGER geocoder, prepared for bulk Census loads"
LABEL org.opencontainers.image.licenses="MIT"

# What the generated Census loader scripts shell out to. shp2pgsql is NOT part
# of postgresql-NN-postgis-3 -- that ships the server-side extension only. The
# client-side loaders live in the separate `postgis` package, whose version
# tracks the same PostGIS release.
RUN apt-get update \
	&& apt-get install --yes --no-install-recommends \
		ca-certificates postgis unzip wget \
	&& rm -rf /var/lib/apt/lists/*

COPY --from=extension \
	/usr/share/postgresql/${PG_MAJOR}/extension/postgis_tiger_geocoder* \
	/usr/share/postgresql/${PG_MAJOR}/extension/

COPY sql/ /usr/local/share/tiger-geocoder/
COPY docker/bin/ /usr/local/bin/
COPY docker/initdb/ /docker-entrypoint-initdb.d/

ENV TIGER_STAGING=/gisdata
RUN mkdir --parents "${TIGER_STAGING}/temp" \
	&& chown --recursive postgres:postgres "${TIGER_STAGING}"

ENTRYPOINT ["tiger-entrypoint"]
CMD ["postgres"]
