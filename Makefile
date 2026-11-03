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

.PHONY: help install check login whoami bootstrap image init plan apply fmt validate scan \
	smoke ingest raw

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

# ------------------------------------------------------------------- AWS

login: ## Sign in for short-lived AWS credentials (up to 12 hours)
	aws login --remote --profile energy-login

whoami: ## The account and identity every command below uses
	aws sts get-caller-identity

bootstrap: ## The state bucket and the image registry (once, and when they change)
	terraform -chdir=infra/bootstrap init -input=false
	terraform -chdir=infra/bootstrap apply -input=false -var=region=$(REGION)

image: ## Build the functions' image and push it to ECR (skipped if ECR has it)
	scripts/image.sh push

init: ## Connect Terraform to its state bucket
	$(TF) init -input=false \
		-backend-config="bucket=energy-tfstate-$$(aws sts get-caller-identity --query Account --output text)" \
		-backend-config="region=$(REGION)"

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

raw: ## Rows per zone and day in energy_raw.day_ahead_prices
	scripts/athena_query.sh "SELECT zone, _logical_date, count(*) AS rows, min(price_eur_mwh) AS min_price, max(price_eur_mwh) AS max_price FROM energy_raw.day_ahead_prices GROUP BY 1, 2 ORDER BY 2, 1"
