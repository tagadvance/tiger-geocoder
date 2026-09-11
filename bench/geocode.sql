-- One transaction = one geocode of a random sampled address, best match only.
-- :nrows is passed by run.sh from the table itself, so every draw is a real row.
-- Errors are caught and logged to bench.failures instead of aborting the run.
\set id random(1, :nrows)
SELECT bench.geocode_safe((SELECT address FROM bench.addresses WHERE id = :id));
