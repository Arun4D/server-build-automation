# Repository Structure

Status: **Phase 1 — Proposed**

The target layout, what lives in each directory, the rules that govern placement, and the
rationale for the non-obvious choices.

---

## 1. Layout

```
server-build-automation/
├── .github/
│   ├── workflows/                        Runtime workflows + CI/CD
│   ├── ISSUE_TEMPLATE/                   Request and defect templates
│   ├── CODEOWNERS                        Ownership per area
│   ├── dependabot.yml                    Dependency updates
│   ├── pre-commit-config.yaml            Local hooks
│   └── pull_request_template.md          The checklist that keeps CI green
│
├── ansible.cfg                           Canonical paths, callbacks, jinja settings
├── requirements.yml                      Collections, pinned
├── requirements-dev.txt                  Linters, test tools
├── execution-environment.yml             The EE definition
├── environment.yml                       Resolver and state-client dependencies
├── .gitignore
├── Makefile                              The commands a developer actually types
├── README.md                             The entry point
│
├── docs/                                 See §2
│
├── schemas/                              JSON Schema for every wire document
│   ├── business-request.schema.json      The §3 contract
│   ├── run-context.schema.json           Resolver output
│   ├── stage-result.schema.json          Per-stage result
│   └── run-result.schema.json            Result artifacts
│
│   (service-request and callback were dropped with the ServiceNow boundary.
│   See schemas/README.md "Why four, not six".)
│
├── inventories/
│   ├── dev/    ├── group_vars/all/       Control-plane hosts only
│   ├── nonprod/└── group_vars/all/
│   └── prod/   └── group_vars/all/
│
├── playbooks/
│   ├── server_build.yml                  The single entry point [AD-01]
│   ├── server_destroy.yml                Governed teardown
│   ├── server_validate.yml               Pre-flight only
│   ├── post_build.yml                    Operator-triggered post-build stage
│   ├── infrastructure/                   Provider-specific stage playbooks
│   ├── os/                               OS-specific stage playbooks
│   ├── post_build/                       Post-build stage playbooks
│   └── stages/                           The 11 stage wrappers
│
├── roles/                                See §4
├── configuration/                        See §5
├── automation/                           See §6
├── execution-environment/                Dockerfile, lock files
├── collections/                          ansible_collections/ — a build artefact
├── scripts/                              The resolver CLI and the state client
├── tests/                                See §7
└── mock/                                 The §10 mock service
```

---

## 2. `docs/`

| Path | Contents |
|---|---|
| `docs/README.md` | The index |
| `docs/architecture/` | Architecture decisions, views, lifecycle, engines, provider abstraction, per-cloud notes, failure/retry, idempotency, CI/CD |
| `docs/api/` | The contract, the error registry, the role dependency model |
| `docs/security/` | Security architecture, secret management |
| `docs/testing/` | The testing strategy |
| `docs/runbooks/` | The operational procedures |
| `docs/roadmap.md` | Phases and exit criteria |
| `docs/assumptions.md` | What was assumed and what happens if it is wrong |
| `docs/open-questions.md` | The decisions still needed |
| `docs/glossary.md` | Terms of art |

`docs/` is the single source of architectural truth. A design decision that exists only in a
pull request description has not been made.

---

## 3. `schemas/`

Every wire document has a JSON Schema, and every one of them is `additionalProperties: false` at
every level.

| File | Validates |
|---|---|
| `business-request.schema.json` | `AD-02` — the engine-neutral, provider-neutral, business-only contract |
| `run-context.schema.json` | The resolver's output: the single effective configuration |
| `stage-result.schema.json` | One stage's result, one entry per host |
| `run-result.schema.json` | The final result artifact |

The `service-request` and `callback` schemas are **not** present: the ServiceNow and AAP boundary
is out of scope, so there is no caller to wrap and nothing to call back. See
[schemas/README.md](../../../schemas/README.md#why-four-not-six).

**These files are contracts, not documentation.** They are validated in CI, they are validated
again in the adapter, and the version in the file is the version in
[AD-20](architectural-decisions.md#ad-20-additive-schema-versioning-only).

The `additionalProperties: false` rule at every level is the security control. Without it, a
contract with `admin_password` is accepted as an unknown-but-tolerated field, and a schema that
tolerates unknown fields is a schema that will eventually accept something dangerous.

---

## 4. `roles/`

Grouped by the resource they act on, matching
[role-dependency-model.md](role-dependency-model.md).

| Group | Roles | Acts on |
|---|---|---|
| `platform/` | `validate_request`, `resolve_configuration`, `naming`, `policy_gate`, `image_resolver`, `run_state`, `report` | The run itself. No infrastructure |
| `cloud/` | `azure_vm`, `aws_ec2`, `gcp_compute` | The compute instance |
| `image/` | `azure_image`, `aws_image`, `gcp_image` | The image reference |
| `os/` | `linux_baseline`, `windows_baseline` | The guest OS |
| `domain/` | `windows_domain_join`, `linux_domain_join` | The AD computer object |
| `dns/` | `dns_registration` | The DNS record set |
| `cmdb/` | `servicenow_cmdb` | The ServiceNow CI |
| `security/` | `cis_linux`, `cis_windows`, `security_agent`, `vulnerability_agent` | The guest's security posture |
| `monitoring/` | `monitoring_agent` | The guest's monitoring |
| `backup/` | `backup_agent` | The guest's backup |

Three rules:

1. **A role in `cloud/` or `image/` is the only place a cloud module may be called.** Enforced
   by a CI gate ([cicd-pipeline.md §2.1 ](cicd-pipeline.md#21-what-each-stage-is-for-and-what-it-cannot-catch)),
   and it is what makes `R-08` a checkable rule rather than an aspiration.
2. **A role depends only on `platform/` and on other `platform/` roles.** A role never includes
   another domain role, so the DAG stays acyclic and the stage order is visible in the
   directory structure.
3. **Every role directory is self-contained**: `tasks/`, `defaults/`, `vars/`, `handlers/`,
   `meta/`, `tests/`. A role that reaches outside its own directory is a coupling that will be
   invisible later.

```
roles/cloud/azure_vm/
├── tasks/
│   ├── main.yml              The six task groups [provider-abstraction.md §2]
│   ├── preflight.yml
│   ├── lookup.yml
│   ├── create_or_adopt.yml
│   ├── converge.yml
│   ├── networking.yml
│   ├── storage.yml
│   ├── wait_for_ready.yml
│   ├── decommission.yml
│   └── assert.yml
├── defaults/main.yml         Every parameter, with a documented default
├── vars/main.yml             The capability declaration [provider-abstraction.md §6]
├── handlers/main.yml
├── meta/main.yml
├── README.md                 What it does, what it requires, what it never does
└── tests/                    Molecule scenarios, incl. the mandatory idempotence one
```

---

## 5. `configuration/`

The whole configuration hierarchy, split by kind rather than by environment. This is the single
most consequential structural decision in the repository, and it is
[configuration-resolution.md](configuration-resolution.md)'s requirement.

| Directory | Contents | The question it answers |
|---|---|---|
| `clouds/` | One file per cloud: regions, capabilities, metadata limits | What does a cloud support? |
| `regions/` | One file per provider: region lists, zones, subnets, quota notes | Where can it be built? |
| `server_roles/` | One file per application role: sizes, counts, security requirements | What does this kind of server look like? |
| `applications/` | One file per application: which roles, which regions, owner, cost centre | What does this application need? |
| `os/` | One per OS family: baseline versions, supported versions | What OS is allowed? |
| `images/` | One per OS: catalogue entries, pins, expiry, revocation | Which image? |
| `environments/` | `dev.yml`, `nonprod.yml`, `prod.yml`: policies, subscriptions, routes | What is different about this environment? |
| `policies/` | `dev.yml`, `nonprod.yml`, `prod.yml`: floors and ceilings | What is permitted? |
| `routing/` | `engine_routing.yml`: environment → engine | Which engine runs this? |
| `tags/` | Canonical key set, per-provider mapping, normalisation rules | How is ownership recorded? |
| `naming/` | Patterns, per-scope DNS zones, reserved words | What is this server called? |

The split is **by kind**, so that adding a new environment is one file in three directories, and
adding a new application is one file. The alternative — `configuration/dev/`,
`configuration/nonprod/`, `configuration/prod/` each containing everything — duplicates the
catalogue three times, and the copies drift. Drift in a duplicated catalogue is not a cosmetic
problem: it means dev builds a server that production cannot, and the difference is discovered in
production.

```
configuration/
├── clouds/azure.yml            # the capability declaration
├── regions/azure.yml           # westeurope, northeurope, ...
├── server_roles/payment_gateway.yml
├── applications/payments.yml
├── os/windows.yml
├── images/windows.yml
├── environments/prod.yml
├── policies/prod.yml
├── routing/engine_routing.yml
├── tags/canonical_keys.yml
└── naming/patterns.yml
```

---

## 6. `automation/`

The engine-specific objects, kept out of `.github/` and out of the Ansible project, because
neither is a natural home for them.

| Path | Contents |
|---|---|
| `github/` | The adapter, composite actions, runner configuration |
| `github/composite/` | Composite actions: contract validation, run-context fetch, artifact upload |
| `github/runner-config/` | The self-hosted runner's systemd unit, install script, hardening |
| `aap/job_templates/` | Job template YAML for import |
| `aap/workflow_templates/` | Workflow template YAML for import |
| `aap/credentials/` | Credential **definitions**. **No secret values.** See below |
| `aap/inventories/` | Inventory source definitions |
| `servicenow/` | The ServiceNow-side objects: a Business Rule, a REST Message, a Flow, a Transform Map |

**`automation/aap/credentials/` holds credential *definitions*, never values.** A file like:

```yaml
---
# automation/aap/credentials/01-cloud-azure-prod.yml
# This defines WHICH credential exists. The secret VALUE is entered in the AAP
# UI or via the API by the platform team and is never committed.
- name: Azure - Production - OIDC
  description: >
    Federated identity for production Azure. The token is exchanged for an
    Azure access token at run time; no client secret is stored anywhere.
  credential_type: "Microsoft Azure"
  inputs:
    client_id: "00000000-0000-0000-0000-000000000000"   # not secret
    subscription_id: "00000000-0000-0000-0000-000000000000"
    tenant_id: "00000000-0000-0000-0000-000000000000"
    # No client_secret. See docs/security/secret-management.md
  managed: true
```

is safe to commit. A file containing the value is not, and a repository rule plus a pre-commit
gitleaks hook enforces the difference. Putting the definitions in version control means the
*set* of credentials is reviewable — a credential nobody declared cannot be used, because the
platform only reads what the inventory of definitions contains.

---

## 7. `tests/`

| Path | Contents |
|---|---|
| `unit/` | The resolver, naming, TagMapper, image, policy, state client |
| `integration/` | Playbook-level, mocked cloud |
| `e2e/` | ServiceNow → engine → cloud → CMDB |
| `molecule/` | Per-role scenarios, run in a container EE |
| `molecule/scenarios/` | Shared scenario fragments (idempotence, tag assertion, lock) |
| `fixtures/` | Golden resolution files, contract corpus, tag matrix, mock specs |
| `security/` | gitleaks config, semgrep rules, the architecture-gate checks |

`tests/molecule/scenarios/` exists so that the idempotence scenario is written once and used by
every role. A mandatory assertion that every role re-implements is a mandatory assertion that
some role will re-implement wrongly.

---

## 8. `scripts/`, `execution-environment/`, `collections/`

### 8.1 `scripts/`

```
scripts/
├── resolve_configuration.py       The CLI. Thin. Delegates to lib/sba_resolver
├── sba_state                      The run-state client
├── verify_tags                    The tag-integrity auditor
└── lib/
    └── sba_resolver/              The pure resolver package
        ├── __init__.py
        ├── models.py               Typed models
        ├── loader.py               Configuration loading
        ├── precedence.py           The merge algorithm
        ├── variables.py            Interpolation
        ├── naming.py               Name generation
        ├── tags.py                 The TagMapper
        ├── images.py               Image selection
        ├── policy.py               Policy evaluation
        ├── errors.py               Error codes
        └── cli.py                  Entry point
```

`lib/sba_resolver` has **no Ansible dependency, no cloud SDK, and no I/O outside reading the
configuration tree.** That is [AD-22](architectural-decisions.md#ad-22-resolver-is-read-only-and-side-effect-free),
and it is what makes the resolver testable to 100% branch coverage
([testing-strategy.md §11 ](../testing/testing-strategy.md#11-coverage)) and callable from both
engines identically.

### 8.2 `execution-environment/`

| File | Purpose |
|---|---|
| `Dockerfile` | The EE image definition |
| `requirements.txt` | Fully pinned, with hashes |
| `requirements-constraints.txt` | Version ceilings |
| `build.sh` | `ansible-builder build --tag sba-ee:<tag>` |
| `verify.sh` | The EE sanity and Molecule tests |
| `manifest.json` | The collection and version manifest, promoted with the digest |

**Pinned with hashes.** An EE built from floating versions is not reproducible, and a
non-reproducible EE means a non-reproducible production build.

### 8.3 `collections/`

Empty in the repository. `ansible-galaxy` writes into `collections/ansible_collections/` when the
project's `collections_path` is set, and `.gitignore`d.

**Not a Collection.** `AD-13`: this is an Ansible *project*, not a collection, because it owns
playbooks, inventories, configuration and the EE. A root `galaxy.yml` would be wrong and would
mislead anyone who tried to consume it from Galaxy.

---

## 9. `.github/`

```
.github/
├── workflows/
│   ├── server-build.yml            Runtime. ServiceNow-triggered
│   ├── server-destroy.yml          Runtime. Approved only
│   ├── server-validate.yml         Runtime. Pre-flight only
│   ├── post-build.yml              Runtime. Operator-triggered
│   ├── ci-lint.yml                 CI. L1-L3
│   ├── molecule.yml                CI. L4
│   ├── integration.yml             CI. L5
│   ├── sec-scan.yml                CI. Security
│   └── ee-build.yml                CI. The EE build and promotion
├── CODEOWNERS
├── ISSUE_TEMPLATE/
│   ├── server_request.yml          A requester asks for a new server role
│   └── bug_report.yml
└── pull_request_template.md
```

Runtime and CI workflows are separated by name and by trigger
([cicd-pipeline.md §1 ](cicd-pipeline.md#1-two-pipelines-one-repository)), because a runtime
workflow with CI credentials is one of the easier mistakes to make and one of the more expensive.

The canonical location for the runtime workflows is `.github/workflows/` and nowhere else
([AD-12](architectural-decisions.md#ad-12-canonical-workflows-live-in-githubworkflows)), because
GitHub only recognises workflows in that directory and a workflow in `automation/github/` is a
file that looks like a workflow and never runs.

---

## 10. `mock/`

```
mock/
├── requirements.txt
├── run.sh
├── servicenow/                    Mock ServiceNow REST + a Business Rule analogue
│   ├── app.py
│   └── fixtures/
├── state_store/                   A local implementation of the run-state store
│   ├── app.py
│   └── adapter.py
└── cloud/                         Optional; a cloud emulator is heavy, so prefer recorded fixtures
    └── README.md
```

Used by L5 and by a developer's local run. The **state store mock must implement the CAS
semantics for real**, because CAS correctness is what the locking design depends on; a mock with
last-write-wins would let a lock bug pass every test.

---

## 11. Placement Rules

| Rule | Enforced by |
|---|---|
| A cloud module call only in `roles/cloud/` or `roles/image/` | CI gate |
| A hard-coded subscription, VNet, subnet, image or OU ID only in `configuration/regions/` or `clouds/` | CI gate |
| A secret only in the credential store, never in `configuration/`, `schemas/`, `workflows/`, `inventories/` | gitleaks + a CI gate |
| Playbook logic in `playbooks/`, never in a role's `tasks/main.yml` | Review |
| A new stage is a new file in `playbooks/stages/`, plus a case in `server_build.yml` | Review |
| A new provider is a role + a catalogue file + a static dispatch entry, never a plugin | CI gate |
| Every new wire document has a schema in `schemas/` | CI gate |
| Every new role has `README.md` and a `tests/` directory | CI gate |
| Every new role has an idempotence scenario | CI gate |
| Documentation of a decision goes in `docs/`, not in a PR description | CODEOWNERS |

The last rule is worth defending, because a decision made in a pull request is invisible six
months later to the person who has to maintain it.

---

## 12. `ansible.cfg`

```ini
[defaults]
inventory                   = inventories/dev
collections_path            = collections:./roles:~/.ansible/collections
roles_path                  = roles
host_key_checking           = True
retry_files_enabled         = False
stdout_callback             = yaml
display_skipped_hosts       = False
gathering                   = smart
fact_caching                = jsonfile
fact_caching_connection     = .facts_cache
fact_caching_timeout        = 3600
interpreter_python          = auto_silent
vault_password_file         = ~/.vault_pass           # outside the repository
deprecation_warnings         = True
forks                       = 20
timeout                     = 60

[privilege_escalation]
become        = True
become_method = sudo
become_user   = root

[ssh_connection]
pipelining   = True
scp_if_ssh   = smart
ssh_args     = -o ControlMaster=auto -o ControlPersist=300s -o ServerAliveInterval=30

[persistent_connection]
command_timeout = 60
connect_timeout = 30
```

| Setting | Why |
|---|---|
| `collections_path = collections:./roles:~/.ansible/collections` | The local path first, so a project role always wins over an installed one of the same name |
| `host_key_checking = True` | **Not disabled.** A build that trusts any host key will connect to whatever answers |
| `vault_password_file` outside the repo | A vault password in the repository is a vault password in Git |
| `forks = 20` | Matches the serial batch size; a smaller value serialises unnecessarily |
| `timeout = 60` | Bounded, so a hung connection fails rather than blocking a run |
| `pipelining = True` | Fewer round trips per module; noticeably faster over WAN links |
| `deprecation_warnings = True` | Surfaces upstream deprecations before they become breaks |

`host_key_checking` is the one that gets "helpfully" disabled by people in a hurry, and it is the
one that would let a build connect to a machine that is not the one it intended.

---

## 13. `requirements.yml`

Collections pinned exactly. Unpinned collections are how a production build changes behaviour
because a dependency shipped a release.

```yaml
---
collections:
  - name: ansible.posix
    version: "1.5.4"
  - name: ansible.windows
    version: "2.3.0"
  - name: ansible.builtin
    version: "2.16.14"
  - name: community.general
    version: "8.6.0"
  - name: community.crypto
    version: "2.22.0"
  - name: amazon.aws
    version: "8.2.0"
  - name: azure.azcollection
    version: "2.5.0"
  - name: google.cloud
    version: "2.3.0"
  - name: kubernetes.core
    version: "3.0.0"     # only if a role needs it; prefer a native module
  - name: community.dns
    version: "2.7.0"
  - name: ansible.netcommon
    version: "6.1.0"
```

Three decisions:

1. **`azure.azcollection` rather than `community.azure`.** The collection was donated to the
   `azure` namespace, and using the old one means a deprecated collection with a slower security
   patch cadence.
2. **`kubernetes.core` is a conditional dependency.** Pulling it in unconditionally adds a large
   surface for something most builds never use. Every extra collection is more code that runs
   with the platform's identity.
3. **A CI gate checks that every namespace a role calls is declared here.** An undeclared
   dependency resolves at build time from whatever happens to be installed, which is
   non-deterministic by construction.

---

## 14. `.gitignore`

```gitignore
# Byte-compiled / caches
__pycache__/
*.py[cod]
.mypy_cache/
.ruff_cache/
.pytest_cache/
.hypothesis/

# Ansible
*.retry
.facts_cache/
collections/ansible_collections/
*.vault_pass
.vault_pass
vault_password_file

# GitHub Actions
# NOTE: .github/workflows/ is NOT ignored. It is the canonical location
# for the runtime workflows (AD-12). Never add it here.
.github/workflow-debug.log

# Test and integration artefacts
tests/output/
tests/.tmp/
*.log
junit.xml
coverage.xml
htmlcov/
.molecule/
tests/molecule/*/scenario-*/

# Local mock state
mock/.state/

# EE build output
execution-environment/context/
execution-environment/build/
*.tar
*.tar.gz

# Credentials — the second line of defence. gitleaks is the first.
*.pem
*.key
*.pfx
*.p12
*.jks
*.keystore
id_rsa*
id_ed25519*
.env
.env.*
secrets.yml
credentials.yml
*.vault

# Editors and OS
.idea/
.vscode/
*.swp
.DS_Store
Thumbs.db
```

Two entries deserve comment:

**`.github/workflows/` is not ignored.** It is tempting to exclude workflow files that contain
what looks like configuration, and doing so would break the platform. `AD-12` makes that
directory canonical, and the runtime workflows must be reviewed and versioned like any other
code.

**`*.key` and `*.pem` are ignored, which is a hazard for a repository that legitimately contains
TLS material.** The platform's answer is that it contains none: TLS material lives in the secret
store. The ignore rule is a safety net for an accidental commit, and the gitleaks hook plus the
CI scan are the control that actually works. Anyone who genuinely needs a certificate in the
repository should raise it, and the right answer will be to store it in the secret store and
reference it by path.

---

## 15. `Makefile`

The commands a developer actually types. Documented commands get used; undocumented ones get
reinvented slightly differently each time.

```makefile
.DEFAULT_GOAL := help
SHELL := /bin/bash

.PHONY: help lint test test-unit test-molecule ee-build ee-push mock clean

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

lint:  ## ansible-lint, yamllint, actionlint, ruff, mypy, shellcheck
	ansible-lint
	yamllint .
	actionlint
	ruff check scripts tests
	mypy scripts/lib/sba_resolver
	shellcheck scripts/*.sh

test: test-unit lint  ## Fast gate
	pytest tests/unit -q

test-unit:  ## Pure unit tests
	pytest tests/unit -q --cov=scripts/lib/sba_resolver --cov-branch --cov-report=term-missing

test-molecule:  ## Role tests in a container EE
	molecule test -s default

ee-build:  ## Build the Execution Environment
	./execution-environment/build.sh

ee-push:  ## Push by digest
	dessl build.yml --push

mock:  ## Run the mock ServiceNow and state store
	./mock/run.sh

clean:  ## Remove caches
	rm -rf .pytest_cache .mypy_cache .ruff_cache .facts_cache .hypothesis
	find . -name __pycache__ -type d -exec rm -rf {} +
```

`test` runs the **fast** gate only. Making the default target the slow one would train people to
use `--no-verify` on commit, which defeats the purpose of having a pre-commit hook.

---

## 16. Rationale for the Non-Obvious Choices

| Choice | Alternative | Why this one |
|---|---|---|
| `configuration/` split by kind | By environment | Adding an environment is 3 files, not a full catalogue copy. Duplicate catalogues drift, and drift means dev and prod differ |
| `roles/` grouped by resource | Flat `roles/` | A flat directory of 20+ roles is unreadable; the grouping is the DAG |
| Provider roles, no plugin API | A Python `CloudProvider` base class | The dispatch is in YAML; a class hierarchy would require dynamic includes, which `AD-08` prohibits ([provider-abstraction.md §1 ](provider-abstraction.md#1-why-a-contract-not-a-base-class)) |
| `automation/aap/` | AAP objects exported from the project | They are engine configuration, not Ansible. Exporting mixes a declarative artefact with the code that consumes it |
| Schemas in the repo | Schemas in the wiki | A schema in a wiki is not validated by anything |
| `collections/` gitignored | Vendored | Upstream, regenerated at EE build time. Vendoring 20 collections is 200 MB of noise in a diff |
| Project, not Collection | `galaxy.yml` | It owns playbooks, inventories and configuration. `AD-13` |
| `mock/` in the repo | Tests only | A local run of the whole platform needs it, and it is a development dependency, not a production one |
| Runtime and CI workflows side by side | Separate directories | GitHub recognises only `.github/workflows/`. A runtime workflow in `automation/github/` looks valid and never runs |

---

## 17. Next

- The full architecture: [logical-architecture.md](logical-architecture.md)
- Role detail: [role-dependency-model.md](role-dependency-model.md)
- Configuration model: [configuration-resolution.md](configuration-resolution.md)
- Pipeline: [cicd-pipeline.md](cicd-pipeline.md)
