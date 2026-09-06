# Thin wrapper over docker compose. Every target here is a one-liner you could
# type by hand; the point is that the flags are easy to get wrong.

COMPOSE ?= docker compose
EXEC    := $(COMPOSE) exec --user postgres db
STATES  ?=

.DEFAULT_GOAL := help

.PHONY: help
help:
	@grep -hE '^[a-z][a-zA-Z0-9_-]*:.*## ' $(MAKEFILE_LIST) \
	| sort \
	| awk 'BEGIN{FS=":.*## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.env:
	@test -f .env || { cp .env.example .env; \
	echo "created .env from .env.example -- set POSTGRES_PASSWORD"; exit 1; }

.PHONY: build
build: .env ## Build the image
	$(COMPOSE) build

.PHONY: up
up: .env ## Start the database
	$(COMPOSE) up --detach --wait

.PHONY: down
down: ## Stop the database
	$(COMPOSE) down

.PHONY: logs
logs: ## Follow the database log
	$(COMPOSE) logs --follow

.PHONY: nation
nation: ## Load the national county/state layers (required, do this first)
	$(EXEC) tiger-load nation

.PHONY: load
load: ## Load states, e.g. make load STATES="OH KY"
	$(EXEC) tiger-load all $(STATES)

.PHONY: index
index: ## Install missing indexes and vacuum analyze
	$(EXEC) tiger-load index

.PHONY: psql
psql: ## Open a psql shell
	$(EXEC) psql

.PHONY: test
test: ## Run the test suite against the running database
	./test/run-tests.bash

.PHONY: lint
lint: ## Shellcheck every script
	shellcheck docker/bin/* docker/initdb/*.sh test/*.bash

# PGDATA is a bind mount, so a snapshot is just a tarball of a directory. The
# database has to be stopped: a tar of a live PGDATA is a torn copy, and it will
# restore cleanly right up until it doesn't.
.PHONY: snapshot
snapshot: down ## Tar the loaded database for transfer to another machine
	tar --create --zstd --file tiger-geocoder-$$(date --utc +%Y%m%d).tar.zst data/

.PHONY: clean
clean: down ## Remove containers; keeps ./data and ./gisdata
	$(COMPOSE) rm --force

# PGDATA belongs to the container's postgres user, so the host cannot unlink it
# without root. Borrow a container rather than asking for sudo.
.PHONY: clean-data
clean-data: down ## Delete the loaded database and download cache (destructive)
	@printf 'Deletes ./data and ./gisdata. Enter to continue, Ctrl-C to abort: '; read -r _
	docker run --rm --volume "$$PWD":/work --workdir /work alpine:3 rm -rf data gisdata
