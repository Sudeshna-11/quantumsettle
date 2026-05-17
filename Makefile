.PHONY: help up down logs wait psql check migrate seed bench test fmt lint clean nuke

SHELL := /bin/sh

help:
	@echo "QuantumSettle dev tasks:"
	@echo "  make up        Start Oracle 23ai (first boot ~2 min)"
	@echo "  make down      Stop container (keeps data volume)"
	@echo "  make logs      Tail container logs"
	@echo "  make wait      Block until Oracle reports healthy"
	@echo "  make check     Verify Python can connect"
	@echo "  make psql      Open SQL*Plus inside the container as app user"
	@echo "  make migrate   Apply DDL in db/01_schema .. db/04_jobs (idempotent reruns ok)"
	@echo "  make seed      Generate fake trades and load (default 10M trades)"
	@echo "  make bench     Run naive-vs-optimized perf benchmarks"
	@echo "  make test      Run pytest + utPLSQL suites"
	@echo "  make fmt       Format Python with ruff"
	@echo "  make lint      Lint Python with ruff"
	@echo "  make clean     Stop container (keep data)"
	@echo "  make nuke      Stop container AND drop data volume (fresh start)"

up:
	docker compose up -d
	@echo ""
	@echo "Oracle starting. First boot can take ~2 minutes."
	@echo "Run: make wait    -- to block until healthy"
	@echo "Run: make logs    -- to tail startup logs"

down:
	docker compose stop

logs:
	docker compose logs -f oracle

wait:
	@echo "Waiting for Oracle to report healthy..."
	@until [ "$$(docker inspect --format='{{.State.Health.Status}}' quantumsettle-oracle 2>/dev/null)" = "healthy" ]; do \
	  sleep 5; printf '.'; \
	done; \
	echo ""; echo "Oracle is healthy."

check:
	python -m quantumsettle.scripts.check_db

psql:
	docker compose exec oracle bash -lc 'sqlplus -L $$APP_USER/$$APP_USER_PASSWORD@$$ORACLE_DATABASE'

migrate:
	python -m quantumsettle.scripts.migrate

seed:
	python -m quantumsettle.faker.run --trades 10000000 --lifecycle-multiplier 5

bench:
	python -m quantumsettle.bench.run

test:
	pytest tests/py -v
	@echo ""
	@echo "TODO Phase 7: invoke utPLSQL test suite"

fmt:
	ruff format py tests

lint:
	ruff check py tests

clean: down

nuke:
	docker compose down -v
