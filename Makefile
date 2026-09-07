# Thin wrapper over docker compose. Every target here is a one-liner you could
# type by hand; the point is that the flags are easy to get wrong.

COMPOSE ?= docker compose
EXEC    := $(COMPOSE) exec --user postgres db
IMAGE   ?= tagadvance/tiger-geocoder:dev
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

# TIGER_WEBSITE_ROOT is passed with an explicit -e rather than relying on the
# service environment: compose interpolates that at container-create time, so a
# variable set on this command line is not reliably visible to an exec into an
# already-running container.
.PHONY: load
load: ## Load states, e.g. make load STATES="OH KY" [WEBSITE_ROOT=https://...]
	$(COMPOSE) exec --user postgres \
		$(if $(WEBSITE_ROOT),--env TIGER_WEBSITE_ROOT=$(WEBSITE_ROOT)) \
		db tiger-load all $(STATES)

.PHONY: index
index: ## Install missing indexes and vacuum analyze
	$(EXEC) tiger-load index

.PHONY: verify
verify: ## Completeness report for loaded states (VERIFY_DEEP=true for the slow, exact check)
	$(COMPOSE) exec --user postgres -e TIGER_VERIFY_DEEP=$(or $(VERIFY_DEEP),false) db \
		tiger-load verify $(STATES)

.PHONY: psql
psql: ## Open a psql shell
	$(EXEC) psql

.PHONY: test
test: ## Run the test suite against the running database
	./test/run-tests.bash

.PHONY: lint
lint: ## Shellcheck every script
	shellcheck docker/bin/* docker/initdb/*.sh test/*.bash

# PGDATA is a bind mount, so a snapshot is just a tarball of a directory -- but
# the cluster belongs to the container's postgres user and is mode 700, so a
# host-side tar cannot read it. Borrow a container, then hand the tarball back.
#
# The database has to be stopped: a tar of a live PGDATA is a torn copy, and it
# will restore cleanly right up until it doesn't.
#
# To move a loaded database to another host, prefer rsync -- it is resumable and
# incremental, which matters at this size:
#     sudo rsync -a --numeric-ids data/ homelab:/srv/tiger-geocoder/data/
# --numeric-ids is required: the cluster must stay owned by the container's uid,
# not remapped to whatever shares that name on the far end.
.PHONY: snapshot
snapshot: down ## Tar the loaded database for transfer to another machine
	docker run --rm --volume "$$PWD":/work --workdir /work $(IMAGE) sh -c \
		'out="tiger-geocoder-$$(date --utc +%Y%m%d).tar.zst"; \
		 tar --create --zstd --file "$$out" data/ && \
		 chown $(shell id -u):$(shell id -g) "$$out"'

.PHONY: clean
clean: down ## Remove containers; keeps ./data and ./gisdata
	$(COMPOSE) rm --force

# PGDATA belongs to the container's postgres user, so the host cannot unlink it
# without root. Borrow a container rather than asking for sudo.
.PHONY: clean-data
clean-data: down ## Delete the loaded database and download cache (destructive)
	@printf 'Deletes ./data and ./gisdata. Enter to continue, Ctrl-C to abort: '; read -r _
	docker run --rm --volume "$$PWD":/work --workdir /work alpine:3 rm -rf data gisdata
