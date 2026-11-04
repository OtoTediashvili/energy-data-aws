# Every command uses the `energy` AWS profile: short-lived credentials from
# `make login`, never access keys. README, "Setup", has the one-time steps.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

AWS_PROFILE ?= energy
REGION ?= eu-central-1
export AWS_PROFILE
export AWS_REGION := $(REGION)

TF := terraform -chdir=infra
CHECKOV_VERSION := 3.4.0
DBT := uv run dbt
DBT_DIRS := --project-dir dbt --profiles-dir dbt
LAKE_BUCKET = energy-lake-$$(aws sts get-caller-identity --query Account --output text)
# Project 1's landed files, for `make backfill`.
FROM ?= $(HOME)/projects/de-pipeline/data/landing

.PHONY: help install check login whoami bootstrap image init sfn-check plan apply fmt validate \
	scan smoke ingest raw dbt-parse dbt-build prices run backfill docs

help: ## List the commands
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-10s %s\n", $$1, $$2}'

# ------------------------------------------------------------------ code

install: ## The Python environment from uv.lock, and the git hooks
	uv sync --locked
	uv run pre-commit install

check: ## Lint, format check, types and tests: what CI runs on the Python
	uv run ruff check src tests
	uv run ruff format --check src tests
	uv run mypy
	uv run pytest

dbt-parse: ## Check the dbt project (models, tests, configs) without touching AWS
	ENERGY_LAKE_BUCKET=not-used $(DBT) parse $(DBT_DIRS)

# ------------------------------------------------------------------- AWS

login: ## Sign in for short-lived AWS credentials (up to 12 hours)
	aws login --remote --profile energy-login

whoami: ## The account and identity every command below uses
	aws sts get-caller-identity

bootstrap: ## The state bucket and the image registry (once, and when they change)
	terraform -chdir=infra/bootstrap init -input=false
	terraform -chdir=infra/bootstrap apply -input=false -var=region=$(REGION)

image: ## Build the two images (functions, dbt) and push them to ECR (skipped if ECR has them)
	scripts/image.sh push

init: ## Connect Terraform to its state bucket
	$(TF) init -input=false \
		-backend-config="bucket=energy-tfstate-$$(aws sts get-caller-identity --query Account --output text)" \
		-backend-config="region=$(REGION)"

sfn-check: ## AWS's own check of the state machine definitions (free, changes nothing)
	scripts/check_state_machines.sh

plan: ## Show what apply would change, and save that plan (run `make image` first)
	$(TF) plan -input=false -var=region=$(REGION) -var=image_tag=$$(scripts/image.sh tag) -out=tfplan

apply: ## Apply the saved plan, exactly as shown
	$(TF) apply -input=false tfplan

fmt: ## Format the Terraform files
	terraform fmt -recursive infra

validate: ## Check formatting, syntax and types, without touching AWS
	terraform fmt -recursive -check infra
	terraform -chdir=infra/bootstrap init -backend=false -input=false > /dev/null
	terraform -chdir=infra/bootstrap validate
	$(TF) init -backend=false -input=false > /dev/null
	$(TF) validate

scan: ## Security checks on the Terraform (checkov; skips explained in .checkov.yaml)
	uvx --from checkov==$(CHECKOV_VERSION) checkov --config-file .checkov.yaml

# --------------------------------------------------------------- the data

smoke: ## Run one query through the Athena workgroup
	scripts/athena_query.sh "SELECT 'Athena works' AS greeting, current_timestamp AS answered_at"

ingest: ## Extract and parse one zone's day: make ingest ZONE=NL DATE=2026-10-30
	scripts/ingest.sh $(ZONE) $(DATE)

dbt-build: ## Build and test the models in Athena: seed, staging view, Iceberg marts
	ENERGY_LAKE_BUCKET=$(LAKE_BUCKET) $(DBT) build $(DBT_DIRS)

prices: ## Daily average prices per zone, from the marts
	scripts/athena_query.sh "SELECT f.market_date, z.country_code AS zone, f.avg_price_eur_mwh AS avg_price, f.min_price_eur_mwh AS min_price, f.max_price_eur_mwh AS max_price, f.covered_minutes FROM energy_marts.fct_daily_prices AS f JOIN energy_marts.dim_bidding_zone AS z ON f.bidding_zone_sk = z.bidding_zone_sk ORDER BY 1, 2"

run: ## Run the daily pipeline now and wait: make run, or make run DATE=2026-11-02
	scripts/run.sh daily $(DATE)

backfill: ## Copy project 1's landed files (FROM=its data/landing), parse them all, rebuild
	ENERGY_LAKE_BUCKET=$(LAKE_BUCKET) uv run python -m energy.backfill "$(FROM)"
	scripts/run.sh backfill

docs: ## dbt's docs and lineage graph on http://localhost:8080 (Ctrl+C stops it)
	ENERGY_LAKE_BUCKET=$(LAKE_BUCKET) $(DBT) docs generate $(DBT_DIRS)
	ENERGY_LAKE_BUCKET=$(LAKE_BUCKET) $(DBT) docs serve $(DBT_DIRS) --port 8080 --no-browser

raw: ## Rows per zone and day in energy_raw.day_ahead_prices
	scripts/athena_query.sh "SELECT zone, _logical_date, count(*) AS rows, min(price_eur_mwh) AS min_price, max(price_eur_mwh) AS max_price FROM energy_raw.day_ahead_prices GROUP BY 1, 2 ORDER BY 2, 1"
