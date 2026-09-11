-- Build a table of real addresses to geocode against, sampled from the loaded
-- data itself. Every one is guaranteed to exist, so this measures the geocoder's
-- best case: throughput, not hit rate. Scans all of tiger.addr once (~minutes).
CREATE SCHEMA IF NOT EXISTS bench;
DROP TABLE IF EXISTS bench.addresses;
CREATE TABLE bench.addresses AS
SELECT row_number() OVER () AS id, address
FROM (
	SELECT format('%s %s, %s', a.fromhn, f.fullname, a.zip) AS address
	FROM tiger.addr AS a
	JOIN tiger.featnames AS f ON f.tlid = a.tlid
	WHERE random() < 0.001
	  AND a.fromhn ~ '^[0-9]+$'
	  AND a.zip IS NOT NULL
	  AND f.fullname IS NOT NULL
	LIMIT 100000
) AS s;
ALTER TABLE bench.addresses ADD PRIMARY KEY (id);
ANALYZE bench.addresses;
SELECT count(*) AS sampled, min(address) AS example FROM bench.addresses;
