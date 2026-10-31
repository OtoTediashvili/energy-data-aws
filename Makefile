# Every command uses the `energy` AWS profile: short-lived credentials from
# `make login`, never access keys. README, "Setup", has the one-time steps.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

AWS_PROFILE ?= energy
REGION ?= eu-central-1
export AWS_PROFILE

TF := terraform -chdir=infra
CHECKOV_VERSION := 3.4.0

.PHONY: help login whoami bootstrap init plan apply fmt validate scan smoke

help: ## List the commands
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-10s %s\n", $$1, $$2}'

login: ## Sign in for short-lived AWS credentials (up to 12 hours)
	aws login --remote --profile energy-login

whoami: ## The account and identity every command below uses
	aws sts get-caller-identity

bootstrap: ## Create the Terraform state bucket (once per account)
	terraform -chdir=infra/bootstrap init -input=false
	terraform -chdir=infra/bootstrap apply -input=false -var=region=$(REGION)

init: ## Connect Terraform to its state bucket
	$(TF) init -input=false \
		-backend-config="bucket=energy-tfstate-$$(aws sts get-caller-identity --query Account --output text)" \
		-backend-config="region=$(REGION)"

plan: ## Show what apply would change, and save that plan
	$(TF) plan -input=false -var=region=$(REGION) -out=tfplan

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

smoke: ## Run one query through the Athena workgroup
	scripts/athena_query.sh "SELECT 'Athena works' AS greeting, current_timestamp AS answered_at"
