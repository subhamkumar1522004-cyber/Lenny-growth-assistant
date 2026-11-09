# The Lenny Growth Assistant — evaluator workflow.
#
# README §5 "Evaluator Quick Start" is the two commands:
#
#   make setup
#   make demo
#
# `demo` intentionally does NOT start or check Ollama for you: Ollama is a
# native host process (architecture.md §3a explains why it is not
# containerized), and there is no reliable cross-platform way to launch it
# from a Makefile. `demo` verifies it if it's already running and prints the
# exact command to start it if not — see `check-ollama` below.

SHELL := /bin/bash
COMPOSE := docker compose
BACKEND_URL := http://localhost:8000
FRONTEND_URL := http://localhost:5173
OLLAMA_URL := http://localhost:11434

.PHONY: setup demo down test test-backend test-frontend build ingest-full \
        check-ollama check-env logs clean ps

## setup: one-time — copy .env.example, pull the demo Ollama model.
setup:
	@if [ ! -f .env ]; then cp .env.example .env; echo "created .env from .env.example — edit it if you want cloud mode"; fi
	@echo "Pulling the demo Ollama model (skips if Ollama is not running)..."
	@command -v ollama >/dev/null 2>&1 && ollama pull llama3.2:1b || \
		echo "Ollama not found on PATH. Install it from https://ollama.com, then run: ollama pull llama3.2:1b"
	@echo "setup complete. Run: make demo"

## demo: start Postgres + backend + frontend, apply schema, load a small
## evaluation corpus, print URLs. This is the "one-command startup".
demo: check-env
	$(COMPOSE) up -d postgres
	@echo "Waiting for Postgres..."
	@until $(COMPOSE) exec -T postgres pg_isready -U lenny -d lenny >/dev/null 2>&1; do sleep 1; done
	$(COMPOSE) build backend frontend
	$(COMPOSE) up -d backend
	@echo "Waiting for the backend to come up..."
	@for i in $$(seq 1 30); do curl -sf $(BACKEND_URL)/api/health >/dev/null 2>&1 && break; sleep 1; done
	@echo "Applying schema (idempotent)..."
	$(COMPOSE) exec -T backend python -m app.cli init-db
	@echo "Checking whether the corpus is already ingested..."
	@if ! $(COMPOSE) exec -T backend python -m app.cli healthcheck 2>/dev/null | grep -q "chunks.*total=[1-9]"; then \
		echo "Ingesting a small evaluation corpus (~25 episodes, a few minutes)..."; \
		$(COMPOSE) exec -T backend python -m app.cli ingest --limit-episodes 25; \
	else \
		echo "Corpus already present — skipping ingestion. Run 'make ingest-full' for the complete corpus."; \
	fi
	$(COMPOSE) up -d frontend
	@$(MAKE) check-ollama
	@echo ""
	@echo "================================================================"
	@echo " Lenny Growth Assistant is up."
	@echo "   Frontend : $(FRONTEND_URL)"
	@echo "   Backend  : $(BACKEND_URL)/docs"
	@echo "   Health   : $(BACKEND_URL)/api/health"
	@echo "================================================================"

## check-env: fail fast with a readable message instead of a confusing
## downstream error, per architecture.md §12.2's startup philosophy.
check-env:
	@if [ ! -f .env ]; then echo "No .env found. Run 'make setup' first."; exit 1; fi
	@command -v docker >/dev/null 2>&1 || { echo "Docker is required. Install Docker Desktop or the Docker Engine, then retry."; exit 1; }

## check-ollama: informational only — never blocks `demo`. The cloud path
## works without Ollama; only the *local* provider needs it.
check-ollama:
	@if curl -sf $(OLLAMA_URL)/api/tags >/dev/null 2>&1; then \
		echo "Ollama detected at $(OLLAMA_URL) — local provider is available."; \
	else \
		echo "Ollama not detected at $(OLLAMA_URL)."; \
		echo "  To use the local demo path: install Ollama, run 'ollama serve',"; \
		echo "  then 'ollama pull llama3.2:1b'. Cloud mode works without it if"; \
		echo "  ANTHROPIC_API_KEY is set in .env."; \
	fi

## ingest-full: the complete transcript corpus (~303 episodes, ~1 hour).
## Not run by `demo` — see architecture.md §7 on evaluator-experience tradeoffs.
ingest-full:
	$(COMPOSE) exec -T backend python -m app.cli ingest

## test: backend + frontend test suites. No live API keys required — see
## backend/tests and README §9 for what is mocked vs skipped.
test: test-backend test-frontend

test-backend:
	cd backend && python3 -m pytest -q

test-frontend:
	cd frontend && npm test --if-present

build:
	cd frontend && npm run build

logs:
	$(COMPOSE) logs -f

ps:
	$(COMPOSE) ps

down:
	$(COMPOSE) down

clean:
	$(COMPOSE) down -v
