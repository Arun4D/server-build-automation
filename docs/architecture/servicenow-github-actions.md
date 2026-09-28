# ServiceNow → GitHub Actions Integration

Status: **Phase 1 — Proposed**

Design for the GitHub Actions execution path: dispatch mechanism, the workflow files, input
contract, environment and branch protection, OIDC identity, callback, and the boundary that
keeps business logic out of the workflow.

Decisions: [AD-09](architectural-decisions.md#ad-09-per-environment-engine-routing) (routing),
[AD-12](architectural-decisions.md#ad-12-canonical-workflows-live-in-githubworkflows) (layout),
[AD-15](architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs) (no secrets in inputs),
[AD-01](architectural-decisions.md#ad-01-single-entry-playbooks--staged-re-entry) (no logic in
the workflow).

---

## 1. Role of This Path

Per [AD-09](architectural-decisions.md#ad-09-per-environment-engine-routing), GitHub Actions
is the **default engine for `dev` and `nonprod`**, and the proven fallback for production. It is
continuously exercised, so a defect surfaces in nonprod rather than during a production build.

It is **not** the CI/CD pipeline for the repository itself — that is a separate concern
([cicd-pipeline.md](cicd-pipeline.md)) with its own workflows and its own branch rules. Runtime
build workflows and CI workflows are kept separate so that a `dev` runtime dispatch cannot
influence what is allowed to merge.

| Path | Triggered by | Branch rule | Purpose |
|---|---|---|---|
| **Runtime** (`server-build.yml`, `server-destroy.yml`, `server-validate.yml`, `post-build.yml`) | ServiceNow adapter, or an operator | Must exist on default branch; runs a pinned `ref` | Execute a server build |
| **CI** (`ci-lint.yml`, `ee-build.yml`, `sec-scan.yml`) | `push` / `pull_request` | Full protection rules | Quality, security, EE build |

---

## 2. End-to-End Flow

```
  ServiceNow                GitHub REST API            GitHub Actions           Platform
      |                          |                          |                     |
 (1)  | build contract           |                          |                     |
      |  (9 fields)              |                          |                     |
      |------------------------->|                          |                     |
 (2)  |                          | OIDC token exchange      |                     |
      |                          |  (client assertion,      |                     |
      |                          |   no stored secret)      |                     |
      |                          |                          |                     |
 (3)  |                          |--POST /actions/workflows/--->                     |
      |                          |   {server-build.yml}/      |                     |
      |                          |    dispatches              |                     |
      |                          |   {ref: <sha>, inputs:{}}  |                     |
      |                          |                          |                     |
 (4)  |                          |<--201 Created (no body)--|                     |
      |                          |   + Location: run url      |                     |
      |                          |                          |                     |
 (5)  |                          |                          |  resolve -> validate  |
      |                          |                          |  -> stages 1..8      |
      |                          |                          |                     |
 (6)  |                          |                          |  write run_result    |
      |                          |<--GET /actions/runs/{id}--|                     |
      |<--poll/backoff-----------|  {status, conclusion,     |                     |
      |                          |   html_url}               |                     |
 (7)  |                          |                          |                     |
      |  callback (P2) from the adapter, not from the runner:                        |
      |<---------------------------------------------------------------------------|
      |  RITM update, work note, audit                                               |
      v
```

Note step 7: the callback originates from the **adapter**, not from inside the workflow. A
workflow step has no stable outbound identity to ServiceNow, and giving one would mean putting
a ServiceNow credential in GitHub Secrets ([AD-15](architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs)).
The workflow's only outbound job is to produce results; the adapter's only job is to move them.
This is what keeps the workflow free of business logic.

---

## 3. Dispatch Mechanism

### 3.1 Choice: `workflow_dispatch` (primary), `repository_dispatch` (secondary)

| Trigger | Use | Why |
|---|---|---|
| `workflow_dispatch` | **Primary.** One workflow per operation, typed inputs | Self-documenting, shows the exact input set in the GitHub UI, per-input typing and validation, listed in the Actions tab, discoverable and auditable by name |
| `repository_dispatch` | Fallback for a single `event_type` fan-out where callers vary | One workflow serves many event types; useful if a future internal publisher needs to trigger builds without the adapter knowing operation names |

Chosen primary: `workflow_dispatch` inputs are a **documented, typed, enumerable contract**,
which is exactly what §28 asks for and what makes the input set reviewable in a pull request
without reading adapter code. `repository_dispatch`'s single free-form `client_payload` gives up
input-level validation and discoverability for very little benefit at our scale.

### 3.2 The hard GitHub constraint

**Both mechanisms resolve the workflow file from the repository's default branch.** A workflow
that exists only on a feature branch cannot be dispatched, and a workflow file changed on a
feature branch does not affect dispatch until merged.

Consequences, all handled explicitly:

| Consequence | Handling |
|---|---|
| The workflow must exist on `main` | `.github/workflows/server-build.yml` is a permanent file; it is never created on a branch |
| The workflow *content* that runs must be pinned | The adapter passes a **pinned `ref`** — a commit SHA or an immutable release tag — never a branch name |
| Editing a workflow on a branch must not silently change production behaviour | The `ref` is a SHA; branch HEAD is irrelevant |
| A workflow file itself is a change surface | It is under the same branch protection, review and CODEOWNERS rules as the playbooks |

This is the practical reason production cannot use a floating branch: with a branch name as
`ref`, the code that builds a production server is whatever happened to be on that branch at
dispatch time, and the only record is after the fact.

### 3.3 Dispatch call

```
POST /repos/{owner}/{repo}/actions/workflows/server-build.yml/dispatches
Authorization: Bearer <OIDC-derived installation token>
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2022-11-28
Content-Type: application/json

{
  "ref": "3f9a1c2e4b7d8a0f1e2c3b4a5d6e7f8091a2b3c4d",     <- pinned SHA or release tag
  "inputs": {
    "run_context_id":  "01HQ8Z...RITM0012345",
    "request_id":      "RITM0012345",
    "environment":     "nonprod",
    "stage":           "all",
    "config_ref":      "3f9a1c2e4b7d8a0f1e2c3b4a5d6e7f8091a2b3c4d"
  }
}
```

Response: `204 No Content`. **There is no run id in the response.** The adapter obtains the run
id from the response `Location`/`Link` header if present, and otherwise from a subsequent
`GET /repos/{o}/{r}/actions/workflows/{wf}/runs?event=workflow_dispatch&created=>={ts}` query
filtered on `head_sha == ref` and the `run_context_id` in the run name. This is an
implementation detail the adapter must handle robustly, and it is why the adapter records
`run_url` before returning success to ServiceNow.

**The adapter therefore also sets the run name.** `run_name: "sba RITM0012345 nonprod"` (or
`run-name:` in the workflow), because a run that cannot be found again by `run_context_id` is a
run that will eventually be lost.

### 3.4 What is *not* passed

```
  NEVER in `inputs`:            NEVER in `env:`            NEVER in the contract
  ─────────────────────         ─────────────────          ──────────────────
  subscription_id               AZURE_CREDENTIALS          any credential
  vnet_id / subnet_id           AWS_SECRET_ACCESS_KEY      any token
  image_id / image_reference    GCP_SA_KEY                 any password
  vm_size                       ANSIBLE_VAULT_PASSWORD     any private key
  security_group_ids            any *_PASSWORD / *_SECRET   any connection string
  domain_ou                     any *_TOKEN
  dns_servers
```

The inputs are the 9 contract fields, a stage selector, and a config ref. That is the whole
input surface ([AD-02](architectural-decisions.md#ad-02-engine-neutral-run-contract-as-the-integration-seam)),
and it is what makes the AI/chatbot forward-compatibility claim structurally true
(§29): there is literally no input that could carry an arbitrary command.

---

## 4. Workflow Files

Canonical location is `.github/workflows/` and nowhere else
([AD-12](architectural-decisions.md#ad-12-canonical-workflows-live-in-githubworkflows)).

```
.github/workflows/
  server-build.yml        full lifecycle, or a single stage via `stage` input
  server-destroy.yml      teardown
  server-validate.yml     re-validate existing servers (drift, compliance, CMDB)
  post-build.yml          Stages 4-7 only, for an existing fleet
  ci-lint.yml             CI: lint, syntax, schema, unit            (§16, §26)
  ee-build.yml            CI: build the EE image                     (Phase 2 deliverable)
  sec-scan.yml            CI: SAST, secrets, deps, IaC, Semgrep      (§16)

automation/github/        supporting content, NOT workflow definitions
  composite/              setup-python, resolve-config, run-stage, upload-results
  runner-config/          runner labels, ephemeral settings, hardening baseline
  README.md               stage → workflow → input mapping
```

### 4.1 `server-build.yml` structure

```yaml
# .github/workflows/server-build.yml
name: SBA Server Build
run_name: "sba ${{ inputs.request_id }} ${{ inputs.environment }} ${{ inputs.stage }}"

on:
  workflow_dispatch:
    inputs:
      run_context_id:      { required: true,  type: string }   # opaque; the state-store key
      request_id:          { required: true,  type: string }
      environment:         { required: true,  type: choice,
                             options: [dev, nonprod] }         # prod is rejected here [AD-09]
      stage:               { required: false, type: choice,
                             default: all,
                             options: [all, validate, provision, os_config, validate_os,
                                      domain_join, install_agents, dns, cmdb] }
      config_ref:          { required: true,  type: string }   # pinned SHA/tag
      correlation_id:      { required: false, type: string }

# Least privilege. Never `write-all`.                                    §11
permissions:
  contents: read
  id-token: write          # required for OIDC cloud auth
  # deliberately NOT: actions: write, pull-requests: write, packages: write,
  # deployments: write, checks: write, security-events: write

concurrency:
  group: sba-${{ inputs.environment }}-${{ inputs.request_id }}
  cancel-in-progress: false    # never cancel a build that may have created resources

jobs:
  build:
    runs-on: [self-hosted, "sba-${{ inputs.environment }}", linux, sba-ee]
    timeout-minutes: 360
    environment: ${{ inputs.environment }}     # dev | nonprod GitHub Environments
    outputs: ...
    steps: ...                                 # §4.2
```

Notes on the header, each of which encodes a decision:

- **`environment` restricted to `[dev, nonprod]`.** A production build dispatched through this
  workflow is rejected at the workflow level, in addition to the routing configuration
  ([AD-09](architectural-decisions.md#ad-09-per-environment-engine-routing)). Two
  independent controls, because "we changed the routing YAML" is a plausible mistake and
  production should not be reachable by it.
- **`permissions` exactly `contents: read` + `id-token: write`.** §11's minimum, nothing more.
  `deployments: write` is deliberately absent — the environment's deployment protection then
  cannot be bypassed by a workflow that asked for more.
- **`cancel-in-progress: false`.** Cancelling a run mid-provision creates the worst state:
  some resources exist, no result was written. Cancellation is an explicit operator action
  ([request-lifecycle.md §6.2 ](request-lifecycle.md#62-cancellation)), never a side effect of a
  newer request.
- **`concurrency` group includes `request_id`.** Two different requests to the same environment
  do not block each other. The environment-wide quota control is a separate, deliberate
  mechanism (a CAS semaphore in the run-state store), not an accident of GitHub's concurrency
  grouping.
- **`runs-on` is always self-hosted.** A hosted runner has no identity to the private
  networks, no hardened state, and no capacity guarantee.

### 4.2 Step sequence

```
 1  checkout          actions/checkout@<pinned SHA>
                       ref: ${{ inputs.config_ref }}
                       persist-credentials: false          # no token left in .git
                       fetch-depth: 1

 2  guard             assert environment is not prod; assert config_ref is a full SHA;
                       assert run_context_id is well-formed.
                       Cheap, and it fails before anything is acquired.

 3  identity          OIDC -> short-lived cloud credential, scope = thapi-contract.md §6                  azure/login  |  aws-actions/configure-aws-credentials
                       |  google-github-actions/auth
                       audience/subject = repo:ORG/REPO:environment:ENV
                       TTL: job duration. No static key exists in GitHub.

 4  setup             python + the EE toolchain. Composite action
                       automation/github/composite/setup-python.

 5  fetch context     read context.json for run_context_id from the run-state store.
                       Uses the job identity; no secret in inputs. Fails closed if absent.

 6  validate          contract + pre-flight. Writes result.validate.json.
                       Fails -> PARTIAL/VALIDATION_FAILED, exit non-zero, callback.

 7  run stage         ansible-playbook playbooks/server_build.yml
                         -e @context.json
                         -e '{"stage": "<stage>"}'
                       Composite action automation/github/composite/run-stage.
                       Exactly one playbook. No stage list in this file.

 8  collect           read result.<stage>.json + run_result.json.

 9  upload            actions/upload-artifact@<pinned SHA>
                       name: sba-result-${{ inputs.request_id }}
                       path: run_result.json, result.*.json
                       retention-days: 90

10  conclusion        exit code from the aggregate status. Non-zero unless SUCCESS.
                       The adapter reads the conclusion, not the logs.
```

Three properties of this sequence are load-bearing:

- **Step 1 uses `persist-credentials: false`.** Otherwise the job's token stays in
  `.git/config` for any later step or hook to read. It is a well-known leak path and it costs
  one line to close.
- **Step 7 is a single `ansible-playbook` invocation** with the stage as a variable. There is no
  `if: stage == 'provision'` ladder, no per-stage shell, no matrix. That is
  [AD-01](architectural-decisions.md#ad-01-single-entry-playbooks--staged-re-entry) expressed
  in a workflow file: the workflow cannot drift from the AAP path because it contains no
  orchestration to drift with.
- **Step 10 derives the conclusion from an artifact**, not from log text
  ([AD-14](architectural-decisions.md#ad-14-result-delivery-via-artifacts-never-log-scraping)).
  A module's output changing, a deprecation warning, or a colour code cannot flip a build's
  reported status.

### 4.3 Composite actions

Reusable YAML, versioned with the repo, individually testable:

| Action | Purpose | Contains business logic? |
|---|---|---|
| `setup-python` | Toolchain matching the EE | no |
| `acquire-identity` | OIDC exchange, single provider per environment | no |
| `fetch-context` | Read `context.json` for a `run_context_id` | no |
| `run-stage` | One `ansible-playbook` invocation + result collection | no |
| `upload-results` | Artifact upload with a fixed retention | no |

A composite action that contained a stage list would be the same duplication problem as
inlining it in the workflow, so `run-stage` takes a stage name and nothing else.

---

## 5. Repository Layout and the Default Branch Constraint

Restated from [AD-12](architectural-decisions.md#ad-12-canonical-workflows-live-in-githubworkflows),
because it is the one place where §4's proposed tree and GitHub's behaviour disagree.

```
  .github/workflows/        ONLY canonical workflow definitions. GitHub ignores all else.
  automation/github/        composite actions, runner config, docs.

  What §4 proposed:      automation/github/workflows/server-build.yml
  What GitHub requires:  .github/workflows/server-build.yml
  Resolution:            workflow moved; automation/github/ repurposed, not deleted.
```

Practical rule for reviewers: **if it is a file GitHub executes, it is in
`.github/workflows/`. If it is a file GitHub does not execute, it is not.**

---

## 6. GitHub Environments and Protection

### 6.1 Environment configuration

| Setting | `dev` | `nonprod` | `prod` |
|---|---|---|---|
| Used by runtime builds | yes | yes | **no** (routed to AAP) |
| Deployment protection rules | none | optional reviewers | required reviewers + wait timer |
| Deployment branch rule | `main` | `main`, `release/*` | release tags only |
| Environment secrets | none | none | none |
| Environment variables | `SBA_ENV`, `SBA_STATE_PREFIX` | same | same |
| OIDC subject claim | `repo:ORG/REPO:environment:dev` | `…:nonprod` | `…:prod` |

**No environment holds a cloud secret.** The entire secret posture for this path is that there
is nothing to store: cloud access is OIDC, and everything else is either in the run-state store
(protected by the job's cloud identity) or an AAP credential
([secret-management.md](../security/secret-management.md#3-github-actions)).

### 6.2 OIDC trust policy

The GitHub OIDC claim is the entire authorisation input to the cloud:

```
  claims: iss=https://token.actions.githubusercontent.com
          aud=api://AzureADTokenExchange        (Azure)
          aud=sts.amazonaws.com                (AWS)
          aud=https://iam.googleapis.com       (GCP)
          sub=repo:ORG/REPO:environment:nonprod:ref:refs/tags/v1.4.0

  The cloud trust policy MUST pin:
    - the exact repository                    (never "any GitHub repo")
    - the exact environment                   (dev | nonprod | prod)
    - an explicit ref/branch/tag allow-list   (release tags for prod)
    - the exact audience
    - optionally: a signed-claims or
      "Require a signed job request" condition
```

Three properties are non-negotiable, and each corresponds to a real attack:

| Property | Attack it prevents |
|---|---|
| Repository pinned to `ORG/REPO` | Any other GitHub repository, including a fork of a dependency, can mint a token for your cloud |
| Environment pinned | A workflow run in `dev` cannot assume the `prod` cloud identity |
| Ref allow-list | A compromised branch or an arbitrary ref (e.g. a PR branch) cannot assume a production identity |

Without the ref allow-list, a pull request branch in the repository is a production cloud
credential — which is exactly the case GitHub's own documentation warns about and the reason
`pull_request`-triggered jobs must never reach a production identity.

### 6.3 `prod` as a fallback engine

If production is ever routed to GitHub Actions (manual override,
[OQ-02](../open-questions.md#2-important--an-answer-is-needed-before-phase-4)), three additional
requirements apply, and they are why the default is AAP:

1. `prod` GitHub Environment must have **required reviewers** and a wait timer.
2. The OIDC trust policy must additionally pin to immutable release tags.
3. The runner pool must be a dedicated, hardened, ephemeral `sba-prod` pool
   ([execution-environment.md §6 ](execution-environment.md#6-runner-hardening)).

This is supported and designed for. It is simply not the recommended default, because AAP
provides credential isolation, job scheduling, retention and a built-in approval model that
would otherwise have to be re-implemented with the same total effort.

---

## 7. Callback and Status Read-Back

| Path | Implementation |
|---|---|
| **Callback** (terminal) | The adapter, after observing a terminal conclusion, posts to ServiceNow. Never from a workflow step |
| **Polling** (in-progress) | The adapter polls `GET /repos/{o}/{r}/actions/runs/{run_id}` with exponential backoff: 30 s, 60 s, 120 s, 300 s, then every 300 s, capped at the stage's p95 budget + 50% |
| **Reconciliation** (safety net) | ServiceNow scheduled job, independent of both ([request-lifecycle.md §8 ](request-lifecycle.md#8-status-reconciliation)) |

**Mapping conclusion → status.** GitHub gives four conclusions; the platform gives more, so the
mapping must be explicit and must not lose information.

| GitHub conclusion | Platform status | Note |
|---|---|---|
| `success` | `SUCCESS` | Only if `run_result.json` agrees. If the workflow succeeded but the artifact says otherwise, the artifact wins — see below |
| `failure` | `PARTIAL` or `FAILED` | The authoritative source is `run_result.json` (`error_code` + host breakdown). `FAILED` alone is never reported without the artifact |
| `cancelled` | `CANCELLED` | Operator action; infrastructure retained |
| `skipped` | `VALIDATION_FAILED` | Only from the guard steps |
| `timed_out` | `FAILED` (`TIMEOUT`) | Which stage timed out comes from the artifact |
| `action_required` / `stale` | `MANUAL_ATTENTION` | A protection rule blocked it; a human must act |

**Artifact authoritative over conclusion.** A workflow can conclude `success` while a stage
wrote `PARTIAL` — for example if a non-fatal path completed the step list. The rule is
therefore: **the platform status comes from `run_result.json`; the GitHub conclusion is
transport metadata.** The adapter reads the artifact first and the conclusion only as a
fallback when the artifact is missing, and records which source it used. This inversion is
deliberate: the artifact is written by the component that actually did the work.

**Callback payload** and idempotency are defined once in
[api-contract.md §6 ](../api/api-contract.md#6-callback-contract), not per-engine, so the AAP
and GitHub callbacks are byte-identical apart from the engine identifier.

---

## 8. Failure and Cancellation

| Situation | GitHub behaviour | Platform action |
|---|---|---|
| Runner lost mid-run | Run fails or stalls; no callback possible | Reconciliation job detects a terminal-without-callback or a stale run → `MANUAL_ATTENTION` |
| OIDC exchange fails | Step 3 fails, no infrastructure touched | `IDENTITY_UNAVAILABLE`, retryable, `VALIDATION_FAILED` |
| Quota exhausted | Pre-flight catches it before any write | `QUOTA_EXCEEDED`, not retryable, `VALIDATION_FAILED` ([failure-and-retry.md §4 ](failure-and-retry.md#4-retry-classification)) |
| Stage fails on host 1 of 2 | `serial` continues to host 2; artifact says `PARTIAL` | `PARTIAL` → ServiceNow "Manual Attention" ([AD-16](architectural-decisions.md#ad-16-forward-fix-over-auto-destroy)) |
| Operator cancels | `POST /actions/runs/{id}/cancel` | Termination handler writes the artefact and emits the callback; **infrastructure is retained** |
| Newer request for the same RITM | `concurrency` group + `cancel-in-progress: false` ⇒ **no cancel**; both run, fingerprint check makes the second a no-op ([idempotency.md §7 ](idempotency.md#7-per-stage-idempotency-contract)) | `duplicate: true`, existing run returned |

The last row is the reason `cancel-in-progress: false` is not negotiable. With it set to
`true`, a retry of a ServiceNow request would cancel the in-flight original — destroying
partially provisioned infrastructure and writing no result.

---

## 9. Observability

| Signal | Source | Destination |
|---|---|---|
| Run conclusion + URL | GitHub REST API | Adapter → run-state store + ServiceNow work note |
| Structured results | `run_result.json` artifact | Run-state store (authoritative, [AD-14](architectural-decisions.md#ad-14-result-delivery-via-artifacts-never-log-scraping)) |
| Job logs (redacted) | GitHub log storage → SIEM | EE log store |
| Workflow run history | GitHub Actions UI/API | Operational dashboard, per-environment run rate |
| OIDC token issuance | Cloud identity provider logs | SIEM — the authoritative record of *which workflow* assumed *which cloud identity* |
| Runner health | Runner registration + job history | Capacity alerting before a build queues |

The cloud-side OIDC log is the most security-relevant of these. It is the independent record
that ties a cloud mutation to a specific GitHub workflow run, and it is what makes "who
created this VM" answerable without trusting the platform's own logs.

---

## 10. Security Controls Summary

| Control | Implementation |
|---|---|
| Least-privilege token | `permissions: {contents: read, id-token: write}` only (§11) |
| No `write-all` | Never; asserted in CI by a workflow-header lint rule |
| No secrets in inputs or `env` | Input allow-list enforced by a custom CI check; `gitleaks` on the workflow files |
| Short-lived cloud identity | OIDC per job, scoped `sub`, no static key in GitHub ([AD-15](architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs)) |
| Pinned action versions | All actions referenced by commit SHA, not tag — a mutable tag on `actions/checkout` is a supply-chain hole |
| No credential persistence | `persist-credentials: false` on checkout |
| Production not reachable | `environment` input restricted to `[dev, nonprod]` + separate AAP routing ([AD-09](architectural-decisions.md#ad-09-per-environment-engine-routing)) |
| Protected branch | Workflows, playbooks and roles under the same protection + CODEOWNERS as code |
| Self-hosted runner isolation | Dedicated per-environment pool, ephemeral, no standing cloud role ([execution-environment.md §6 ](execution-environment.md#6-runner-hardening)) |
| No cancellation of builds | `cancel-in-progress: false` |
| Schema validation at the edge | Contract validated by the adapter *and* again in the workflow guard step |
| Audit | Every dispatch produces an immutable `request.json` + `fingerprint.json` before any work begins |

---

## 11. Testing This Path

| Level | Scope | Notes |
|---|---|---|
| Workflow lint | YAML validity, action SHA pinning, `permissions` allow-list, no secrets in inputs/env, no `write-all` | Runs in CI on every PR; a violation blocks merge |
| Action pinning | All `uses:` are 40-char SHAs | Custom check |
| Dispatch contract test | Mock GitHub API; assert `ref` is a SHA, inputs match the allow-list, permissions minimal | Unit |
| Adapter idempotency | Duplicate contract ⇒ one dispatch; modified contract ⇒ `409` | Unit |
| Artifact-authoritative test | Workflow `success` + artifact `PARTIAL` ⇒ reported `PARTIAL` | Unit |
| Molecule | Stage role behaviour on a local/cloud-sandbox target | Integration |
| Nonprod E2E | Full ServiceNow → GitHub → dev cloud build → CMDB | Integration, run nightly |
| OIDC negative tests | Wrong environment claim, wrong repo, wrong ref, wrong audience ⇒ all denied | Integration, in the sandbox |
| Production parity | Same stage sequence produces the same result on AAP and GitHub | Integration — the real test of [AD-01](architectural-decisions.md#ad-01-single-entry-playbooks--staged-re-entry) |

The **production parity test** deserves emphasis: it runs the identical stage list through
both engines and asserts identical `context.json` and equivalent `run_result.json`. It is the
mechanical proof that the two execution paths have not diverged, and it is the control that
keeps [AD-21](architectural-decisions.md#ad-21-single-active-engine-per-run)'s "one
implementation" claim honest over time rather than only at design time.

---

## 12. Known Constraints and Accepted Trade-offs

| Constraint | Consequence | Accepted because |
|---|---|---|
| Workflow must exist on the default branch | Cannot dispatch a workflow that only exists on a branch | GitHub behaviour; mitigated by pinned `ref` ([AD-12](architectural-decisions.md#ad-12-canonical-workflows-live-in-githubworkflows)) |
| Dispatch returns no run id | Adapter must resolve the run via the `Location` header or a filtered query | GitHub API; mitigated by a deterministic run name and by recording `run_url` before returning success |
| No inbound webhook for job completion | Status must be polled | Native design on both engines; polling + callback + reconciliation is sufficient |
| Hosted runners unsuitable for prod cloud access | Self-hosted pool required | No alternative without weakening the OIDC trust policy |
| GitHub log retention is finite | Logs are not the audit record | By design ([AD-14](architectural-decisions.md#ad-14-result-delivery-via-artifacts-never-log-scraping)); the run-state store and the cloud audit log are the records |
| No cross-engine handoff mid-run | Failover is a manual runbook action | [AD-21](architectural-decisions.md#ad-21-single-active-engine-per-run); possible precisely because run state is external to both engines |

---

## 13. Next

- The AAP path (same contract, different scheduler): [servicenow-aap.md](servicenow-aap.md)
- Engine-neutral contract and callbacks: [api-contract.md](../api/api-contract.md)
- Secret patterns for this engine: [secret-management.md](../security/secret-management.md)
- EE and runner hardening: [execution-environment.md](execution-environment.md)
- Repository CI/CD (distinct from runtime workflows): [cicd-pipeline.md](cicd-pipeline.md)
