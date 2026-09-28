# CI/CD Pipeline Design

Status: **Phase 1 — Proposed**

The pipeline that builds, verifies, secures and promotes the platform's own code and its
Execution Environment. Distinct from the *runtime* workflows that execute server builds
([servicenow-github-actions.md](servicenow-github-actions.md#1-role-of-this-path)).

---

## 1. Two Pipelines, One Repository

Confusing these is a common and dangerous mistake: if a `dev` runtime dispatch can influence
what merges, the supply chain is not protected.

| | **CI/CD pipeline** | **Runtime pipeline** |
|---|---|---|
| Workflows | `ci-lint.yml`, `sec-scan.yml`, `ee-build.yml`, `molecule.yml`, `integration.yml` | `server-build.yml`, `server-destroy.yml`, `server-validate.yml`, `post-build.yml` |
| Trigger | `pull_request`, `push` to a protected branch, `schedule` | ServiceNow adapter, or an operator |
| Purpose | Quality, security, EE build, promotion | Execute a server build |
| Credentials | CI identity; **never** a production cloud identity | Job-scoped OIDC for the target environment |
| Branch rule | Full protection | Must exist on the default branch ([AD-12](architectural-decisions.md#ad-12-canonical-workflows-live-in-githubworkflows)) |
| Who can trigger | A developer, by opening a PR | ServiceNow, or an operator with the environment's approval |

**The separation rule:** a runtime workflow may never run with a CI identity, and a CI workflow
may never hold a production cloud identity. A `pull_request` event in particular must be
**structurally incapable** of reaching a production cloud role — which is why the OIDC trust
policies pin the ref
([security-architecture.md §3 ](../security/security-architecture.md#3-identity-model)).

---

## 2. Pipeline Stages

```
  PR opened
     │
     ▼
  ┌──────────────┐
  │ S1 Pre-flight│  YAML parse · schema validation · file permission check
  └──────┬───────┘
     ▼
  ┌──────────────┐
  │ S2 Lint      │  ansible-lint · yamllint · actionlint · python lint
  └──────┬───────┘
     ▼
  ┌──────────────┐
  │ S3 Security  │  SAST · gitleaks (tree + history) · dependency review
  │    scan      │  Trivy · custom architecture gates
  └──────┬───────┘
     ▼
  ┌──────────────┐
  │ S4 Unit test │  Resolver (pure) · naming · TagMapper · image selection · policy
  └──────┬───────┘
     ▼
  ┌──────────────┐
  │ S5 Syntax    │  --syntax-check · --list-tasks on every playbook
  └──────┬───────┘
     ▼
  ┌──────────────┐
  │ S6 Molecule  │  Role scenarios, incl. idempotence, in a container EE
  └──────┬───────┘
     ▼
  ┌──────────────┐
  │ S7 Contract  │  Schema negatives · cross-engine parity · golden resolution files
  └──────┬───────┘
     ▼
  ══════╪══════  ── required status checks; all must be green
     ▼
  ┌──────────────┐
  │ S8 Merge to  │  2 approvals · CODEOWNERS · signed commit · squash
  │   main       │
  └──────┬───────┘
     ▼
  ┌──────────────┐
  │ S9 EE build  │  Build · sanity tests · scan · Molecule INSIDE the EE · push by digest
  └──────┬───────┘
     ▼
  ┌──────────────┐
  │ S10 dev      │  AAP dev project -> digest.  Smoke test.
  └──────┬───────┘
     ▼
  ┌──────────────┐
  │ S11 nonprod  │  release/* branch -> tag.  Full E2E in a sandbox.
  └──────┬───────┘
     ▼
  ══════╪══════  ── approval
     ▼
  ┌──────────────┐
  │ S12 prod     │  prod project -> the SAME digest as nonprod.  Canary request.
  └──────────────┘
```

### 2.1 What each stage is for, and what it cannot catch

| Stage | Catches | Cannot catch |
|---|---|---|
| S1 | Malformed YAML/JSON, schema violations | Anything semantic |
| S2 | Style, FQCN violations, workflow syntax errors | Runtime behaviour |
| S3 | Committed secrets, injection patterns, known CVEs, and the **architecture gates** specific to this project | Logic errors |
| S4 | Resolver logic, naming, tagging, image selection, policy | Anything needing a cloud account |
| S5 | Unimportable roles, undefined variables at parse time | Runtime failures |
| S6 | Role behaviour and **idempotence** on a real target | Cross-role sequencing |
| S7 | Stage sequencing, status roll-up, contract negatives, cross-engine parity | Production-scale behaviour |
| S8-S12 | Everything else, in increasing blast radius | — |

The three custom gates in S3 are the ones specific to this design, and off-the-shelf tooling
would not catch them:

| Gate | Catches | Enforces |
|---|---|---|
| Hard-coded ID gate | A subscription / VPC / subnet / image / OU ID in source | [I-8](architectural-decisions.md#3-cross-cutting-invariants) |
| Cloud module confinement | A provider module outside `roles/cloud`+`roles/image` | [R-08](enterprise-architecture.md#9-architecture-risk-register) |
| No secrets in inputs | A credential in a workflow input or `env` | [AD-15](architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs) |
| Action SHA pinning | A mutable action tag | Supply chain |
| Workflow permission allow-list | `write-all` or an unnecessary permission | §11 |
| Input allow-list | A new workflow input that is not on the list | [I-1](architectural-decisions.md#3-cross-cutting-invariants) |
| `no_log` rule | A credential-consuming task without `no_log` | §15 |
| `sba_` prefix rule | A platform variable that bypasses the contract | Consistency |
| Dependency declaration | A module namespace not in `requirements.yml` | [execution-environment.md §2.5 ](execution-environment.md#25-version-consistency) |
| Live region / tag rule | A config value referencing a real production resource | [I-8](architectural-decisions.md#3-cross-cutting-invariants) |

Each corresponds to a specific way this architecture could be undermined by a well-intentioned
contributor. That is what makes them worth writing as CI checks rather than review comments.

---

## 3. Branch and Promotion Model

### 3.1 Branches

| Branch / tag | Purpose | Runs in | Deployable to |
|---|---|---|---|
| `main` | Development trunk | dev | dev |
| `feature/<name>` | Work in progress | dev (PR) | nothing |
| `bugfix/<name>` | Fix | dev (PR) | nothing |
| `release/<x.y>` | Release candidate | dev, nonprod | nonprod |
| `v<x.y.z>` (tag) | Released version | dev, nonprod, prod | **prod** |
| `hotfix/<name>` | Urgent prod fix | dev, nonprod | via a patch tag, with an expedited review |

**Production references tags, never branches.** A branch is a moving reference; a tag is
immutable. This is what makes "which code built this server" answerable, and it aligns with the
OIDC trust policy's ref allow-list and with the AAP project's `scm_branch`
([servicenow-aap.md §4 ](servicenow-aap.md#4-projects)).

### 3.2 Environment ↔ git mapping

| Environment | AAP project `scm_branch` | GitHub Environment | EE reference | Cloud cell |
|---|---|---|---|---|
| dev | `main` | `dev` | Tag (fast-moving) | Sandbox |
| nonprod | `release/*` | `nonprod` | Digest | Nonprod |
| prod | Release tag | `prod` (fallback only) | **Digest, = nonprod** | Prod |

### 3.3 Hotfix path

```
  1. branch  hotfix/<name> from the current release tag   (never from main)
  2. the same S1-S7 gates, expedited but not skipped
  3. 1 approval from the owning team + 1 from the platform team
  4. tag v<x.y.z+1>; promote through nonprod (may be a reduced suite, recorded)
  5. production approval; prod project -> the new digest
  6. post-release: merge the hotfix into main
```

Step 1 matters: branching from `main` for a production fix ships whatever is in `main` along with
the fix. Step 6 matters because a hotfix that never reaches `main` will be reverted by the next
merge.

---

## 4. Mandatory Checks

All blocking. A merge is impossible while any is red, and an admin bypass is a logged
break-glass event.

### 4.1 Pre-flight

| Check | Tool |
|---|---|
| YAML validity | `yamllint` + a parser check |
| JSON schema validity | `ajv` / `check-jsonschema` against `schemas/*.json` |
| File permissions | No file with the executable bit that should not have it; no world-readable secret-ish file |
| Line endings and encoding | Consistent UTF-8, LF |

### 4.2 Lint

| Check | Tool | Blocking |
|---|---|:--:|
| Ansible best practices, FQCN, `name`, state, idempotence hints | `ansible-lint` | yes |
| `no_log` on credential-consuming tasks | custom `ansible-lint` rule | yes |
| YAML style | `yamllint` | yes |
| Workflow syntax and expressions | `actionlint` | yes |
| Python (resolver, state client) | `ruff` + `mypy` | yes |
| Shell | `shellcheck` | yes |
| Markdown | `markdownlint` | advisory |
| Local hooks | `pre-commit` | advisory (CI is authoritative) |

### 4.3 Security

| Check | Tool | Blocking |
|---|---|:--:|
| Secret scanning, tree | `gitleaks` | yes |
| Secret scanning, **history** | `gitleaks` over full history | yes |
| SAST — Ansible | `semgrep` (ansible ruleset) | yes |
| SAST — Python | `bandit` + `semgrep` | yes |
| Dependency vulnerabilities | `pip-audit` | yes |
| Dependency review (new deps in a PR) | `dependency-review` | yes |
| Collection versions pinned | custom check | yes |
| Container image (on EE build) | `trivy`, `checkov` | yes |
| IaC (if any) | `checkov` | conditional ([C-18](architectural-decisions.md#2-requirement-conflict-register)) |
| Workflow actions pinned by SHA | custom check | yes |
| Workflow permissions minimal | custom check | yes |
| Architecture gates (§2.1) | custom checks | yes |

### 4.4 Test

| Suite | Trigger | Notes |
|---|---|---|
| Resolver unit | Every PR | Fast, no cloud. Golden files + property tests |
| Naming/TagMapper/image/policy unit | Every PR | Includes the ≤15 and GCP-label assertions |
| Contract negative | Every PR | Forbidden fields, enum fuzzing, injection corpus |
| Syntax + list-tasks | Every PR | |
| Molecule (per role) | Every PR | Container EE, idempotence scenario required |
| Molecule (in the built EE) | On EE build | The only test that proves the EE is complete |
| Integration (sandbox cloud) | Merge to `main`; nightly | Real cloud resources, tagged, auto-expired |
| E2E (ServiceNow → engine → cloud → CMDB) | Nightly; pre-release | Both engines |
| **Cross-engine parity** | Nightly; pre-release | Identical stage list on both engines ⇒ identical `context.json` |
| Canary leak test | Nightly; pre-release | Canary credential; search every sink |
| OIDC negative tests | Nightly; per environment | Wrong repo / env / ref / audience ⇒ denied |
| Privilege tests | Nightly; per environment | Read identity cannot write |

The three bolded suites are the ones that protect the architecture rather than the code, and
they are the ones most often omitted. Cross-engine parity is what keeps
[AD-01](architectural-decisions.md#ad-01-single-entry-playbooks--staged-re-entry) honest;
the canary leak test is what keeps
[AD-15](architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs) honest; the OIDC negative
tests are what keep the cloud trust policies from being silently misconfigured.

---

## 5. Environment Configuration and Promotion

### 5.1 What is promoted vs what is configured per environment

| Promoted (identical across environments) | Configured per environment |
|---|---|
| All `roles/**`, `playbooks/**` | `configuration/environments/<env>.yml` |
| `schemas/**` | `configuration/policies/<env>.yml` |
| `tests/**` | `configuration/routing/engine_routing.yml` |
| `execution-environment/**` (pinned) | AAP project `scm_branch`, EE digest, job templates, credentials |
| `ansible.cfg`, `requirements.*` | GitHub Environment protection, runner pool |
| `configuration/clouds/`, `regions/`, `server_roles/`, `os/`, `images/` | |

Code is identical across environments. **Policy and routing differ**, and that is exactly the
right split: the security posture of production should differ from dev, while the automation
should not.

A consequence worth stating: a production build is not a different codebase. It is the same code
with a different policy floor. That makes "what is different in production?" answerable by
reading `configuration/policies/production.yml` and `configuration/environments/prod.yml` —
two files — rather than by diffing two codebases.

### 5.2 Golden resolution files as promotion control

Configuration changes are the highest-risk changes in this repository, because they silently
change what production builds. The mitigation is that **every catalogue change regenerates the
golden resolution files, and the diff is reviewed.**

```
  configuration/applications/payments.yml changed
        │
        ▼
  CI regenerates tests/fixtures/golden/*.json
        │
        ▼
  git diff shows exactly which resolved values changed for which combinations
        │
        ▼
  A reviewer sees: "vm_size Standard_D4s_v6 -> Standard_D8s_v6 for 3 combinations"
```

Without this, a one-character change to a default would alter production infrastructure with no
visible diff. With it, every configuration change is self-documenting and reviewable on its own
terms — and it doubles as the regression test suite for the resolver
([configuration-resolution.md §13 ](configuration-resolution.md#13-testing)).

---

## 6. Secrets in CI

| Secret | Holder | Scope |
|---|---|---|
| EE registry push token | GitHub Actions OIDC or a scoped token | This repo's packages only |
| Cloud read identity | OIDC (CI) | Sandbox and nonprod only. **Never** a production identity for a `pull_request` |
| Sandbox cloud credentials | OIDC (CI) | Sandboxes only |
| Integration test secrets | OIDC + canary values | Test-only |
| Third-party API tokens (scanners) | Repository secrets, environment-scoped | Read-only |

**CI has no production cloud identity, ever.** Not for a `pull_request`, not on `main`, not
manually. A CI compromise is then bounded to sandboxes and nonprod, which is a materially
different incident from a CI compromise that can provision production.

`environment: prod` is never used by a CI workflow. The production identity exists only in the
AAP prod project, reachable only by the launch-only `svc-sba-servicenow` token and by a platform
operator with a product approval.

---

## 7. Observability and Pipeline Operations

| Signal | Use |
|---|---|
| Workflow run history and duration | Trend; a slowing pipeline erodes merge discipline |
| Required-check duration budget | If lint takes 20 minutes, people batch changes and review less carefully. A budget is an engineering constraint, not a nice-to-have |
| Flake rate per test | A flaky test trains people to re-run rather than fix. Quarantine with an owner and an expiry |
| Security scan findings over time | A finding that is routinely "allowed" is a control that is not a control |
| EE build duration and size | Growth in the collection set is a signal of dependency creep |
| Canary leak test result | The single most important CI signal for [AD-15](architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs) |
| Cross-engine parity result | The signal for [AD-01](architectural-decisions.md#ad-01-single-entry-playbooks--staged-re-entry) |
| Coverage of the resolver and TagMapper | The two highest-leverage pure components |

**Flake handling.** A quarantined test has a named owner and an expiry date. Unbounded
quarantine is how a pipeline loses its authority, because a red test that everyone ignores is
worse than no test at all.

---

## 8. Release Management

| Artifact | Versioned by | Promoted by |
|---|---|---|
| Repository content | Semver tag `v<x.y.z>` | The branch model |
| Execution Environment | Content digest | dev → nonprod → prod, digest unchanged between nonprod and prod |
| Schemas | `schema_version` in the file | Additive within a major ([AD-20](architectural-decisions.md#ad-20-additive-schema-versioning-only)) |
| Error code registry | Documented in [api-contract.md §3.2 ](../api/api-contract.md#32-error-code-registry) | Additive only; a code is never renamed or repurposed |
| Golden resolution files | Regenerated per configuration change | Reviewed in the PR |

Semantic versioning applies to the **contract and the EE**, not to every playbook change:

| Change | Version impact |
|---|---|
| A new optional contract field | Minor |
| A new error code | Minor |
| A new catalogue entry for a new application | Minor |
| A new stage | **Major** — it changes the observable lifecycle, and consumers (the ServiceNow flow) must be updated |
| A removed/retyped contract field | **Major** |
| A change to a policy floor that could reject an existing pattern | **Major** for the contract's consumers |
| A bug fix in a role | Patch |
| A new role | Minor |
| A new provider | **Major** — the platform's capability surface changes |

That last row is the honest version of "additive changes only": adding a cloud is a major
version, because a consumer that assumed three providers now has to handle four. Additive
applies to the shape of a document, not to the size of the world.

---

## 9. Rollback

| Situation | Action | Time to safe |
|---|---|---|
| Bad playbook/role in prod | Re-point the prod AAP project at the previous tag; the EE digest is unchanged | <5 min |
| Bad EE in prod | Re-point the prod project at the previous digest | <5 min |
| Bad configuration (catalogue) | Revert the commit; the next run resolves to the previous values. **Existing servers are unaffected** — the catalogue governs new builds | Next run |
| Bad policy floor | Revert; a `POLICY_BLOCKED` run costs nothing, so a bad policy is detected before any damage | Immediate |
| Broken contract (a bad release) | Revert the AAP project to the previous tag; consumers keep the version they sent (additive compatibility) | <5 min |
| Compromised credential | [Emergency rotation](../security/secret-management.md#71-emergency-rotation-procedure) | <15 min, no deploy |
| Compromised EE image | Rebuild from a known-good commit, re-scan, re-promote | ~30 min |

**Configuration rollback is instant and free** because a policy or catalogue change only affects
*future* builds, and a bad one is caught by the policy gate or by the first sandbox run before
it reaches production. That property is worth preserving deliberately: it is a direct benefit of
resolving configuration from reviewed data rather than encoding it in code.

---

## 10. Next

- EE build and promotion detail: [execution-environment.md](execution-environment.md)
- Testing strategy: [../testing/testing-strategy.md](../testing/testing-strategy.md)
- Runtime workflows (distinct from CI): [servicenow-github-actions.md](servicenow-github-actions.md)
- Roadmap and phase exit criteria: [../roadmap.md](../roadmap.md)
