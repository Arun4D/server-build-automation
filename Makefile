# Makefile for the Server Build Automation Platform.
#
# The commands a developer actually types. Documented commands get used;
# undocumented ones get reinvented slightly differently each time.
#
# Phase 1: structure only. Every target is defined, none of them do anything
# yet, because the implementation lands in Phase 2 onwards.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# The fast gate is the default. Making the slow one the default trains people
# to use --no-verify, which defeats the point of a pre-commit hook.
.PHONY: help lint lint-ansible lint-yaml lint-py lint-shell test test-unit \
        test-molecule test-integration schemas golden ee-build ee-verify \
        mock clean

## ---------------------------------------------------------------- help ----

help:  ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / \
		{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

## ---------------------------------------------------------------- lint ----

lint: lint-ansible lint-yaml lint-py lint-shell  ## Run every linter

lint-ansible:  ## ansible-lint, plus a syntax and task-list check
	ansible-lint
	ansible-playbook --syntax-check playbooks/server_build.yml
	ansible-playbook --list-tasks playbooks/server_build.yml

lint-yaml:  ## yamllint, plus the architecture gates
	yamllint .
	@echo "Architecture gates run in CI (tests/security/gates). See"
	@echo "docs/architecture/cicd-pipeline.md section 2.1."

lint-py:  ## ruff and mypy over the resolver and the state client
	ruff check scripts tests
	ruff format --check scripts tests
	mypy scripts/lib/sba_resolver

lint-shell:  ## shellcheck over every shell script
	shellcheck scripts/*.sh execution-environment/*.sh mock/*.sh 2>/dev/null || true

## ---------------------------------------------------------------- test ----

test: test-unit lint  ## The fast gate. Same as the PR merge gate, minus Molecule

test-unit:  ## Pure unit tests: resolver, naming, TagMapper, image, policy, state
	pytest tests/unit -q --cov=scripts/lib/sba_resolver --cov-branch --cov-report=term-missing

test-molecule:  ## Role tests in a container Execution Environment
	molecule test -s default

test-integration:  ## Playbook-level, with mocked cloud APIs
	pytest tests/integration -q

## ------------------------------------------------------------- schemas ----

schemas:  ## Validate every JSON Schema, then the contract fixtures against them
	# Two distinct checks, and conflating them is a mistake: a schema is NOT an
	# instance of itself. --check-metaschema asks "is this a valid schema?";
	# --schemafile asks "does this document satisfy that schema?". The old
	# single command did the second with the schemas as the instances, which
	# fails on every file and tells you nothing about the schemas themselves.
	check-jsonschema --check-metaschema schemas/*.json
	@if [ -d tests/fixtures/contracts ]; then \
		for pair in \
			"business-request:valid/requests" \
			"run-context:valid/contexts" \
			"stage-result:valid/stage-results" \
			"run-result:valid/run-results"; do \
			s="$${pair%%:*}"; d="tests/fixtures/contracts/$${pair##*:}"; \
			set -- $$d/*.json; \
			[ -e "$$1" ] || continue; \
			echo "  $$s <- $$d"; \
			check-jsonschema --schemafile "schemas/$$s.schema.json" "$$@"; \
		done; \
		for pair in \
			"business-request:invalid/contracts" \
			"run-context:invalid/contexts"; do \
			s="$${pair%%:*}"; d="tests/fixtures/contracts/$${pair##*:}"; \
			[ -d "$$d" ] || continue; \
			echo "  $$s <- $$d (each MUST be rejected)"; \
			! check-jsonschema --schemafile "schemas/$$s.schema.json" "$$d"/*.json; \
		done; \
	else \
		echo "  no tests/fixtures/contracts yet - metaschema check only"; \
	fi

golden:  ## Regenerate the golden resolution files, then show the diff for review
	@echo "Phase 2. A configuration change regenerates these, and the diff"
	@echo "is the review artefact. See docs/architecture/cicd-pipeline.md 5.2."

## ------------------------------------------------------------------ ee ----

ee-build:  ## Build the Execution Environment
	ansible-builder build --file execution-environment.yml --tag sba-ee:dev

ee-verify:  ## Build the EE, then run the Molecule suite INSIDE it
	ansible-builder build --file execution-environment.yml --tag sba-ee:dev
	ansible-builder exec --image sba-ee:dev -- make test-molecule

## ---------------------------------------------------------------- mock ----

mock:  ## Run the mock ServiceNow and the mock run-state store
	./mock/run.sh

## --------------------------------------------------------------- clean ----

clean:  ## Remove caches
	rm -rf .pytest_cache .mypy_cache .ruff_cache .facts_cache .hypothesis
	rm -rf htmlcov .coverage coverage.xml junit.xml
	find . -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
	find . -name '*.pyc' -delete 2>/dev/null || true
