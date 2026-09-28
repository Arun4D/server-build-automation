# Enterprise Architecture

Status: **Phase 1 — Proposed** · Part of the [§32 required first output](../../PROJECT_BOOTSTRAP.md)

Scope: system context, container, deployment and cross-cutting views for the Multi-Cloud
Server Build Automation Platform ("SBA"). All decisions referenced as `AD-nn` are defined in
[architectural-decisions.md](architectural-decisions.md).

---

## 1. Design Goals

Ordered. When two goals conflict, the higher one wins.

| # | Goal | Consequence in the design |
|---|---|---|
| G-1 | **The platform is not a shell passthrough.** A requester never supplies a technical parameter. | Contract is 9 business fields with `additionalProperties: false` ([AD-02](architectural-decisions.md#ad-02-engine-neutral-run-contract-as-the-integration-seam)). Everything else is derived. |
| G-2 | **One implementation, two execution engines.** | A single entry playbook and role library; GHA and AAP are schedulers only ([AD-01](architectural-decisions.md#ad-01-single-entry-playbooks--staged-re-entry), [AD-21](architectural-decisions.md#ad-21-single-active-engine-per-run)). |
| G-3 | **Deterministic and reproducible.** | Same contract + same catalogue version ⇒ same configuration ([AD-22](architectural-decisions.md#ad-22-resolver-is-read-only-and-side-effect-free)). Images are pinned ([AD-07](architectural-decisions.md#ad-07-image-catalogue-with-pinning-and-expiry)). Code version is recorded ([AD-20](architectural-decisions.md#ad-20-additive-schema-versioning-only), I-12). |
| G-4 | **Safe to run twice, safe to resume, safe to fail.** | Durable run state, staged re-entry, artifact-based results, forward-fix failure model ([AD-04](architectural-decisions.md#ad-04-run-state-store-is-the-execution-source-of-truth), [AD-14](architectural-decisions.md#ad-14-result-delivery-via-artifacts-never-log-scraping), [AD-16](architectural-decisions.md#ad-16-forward-fix-over-auto-destroy)). |
| G-5 | **No long-lived secrets, anywhere, ever.** | OIDC/managed identity end to end; nothing secret crosses an input boundary ([AD-15](architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs)). |
| G-6 | **Full auditability.** | Every mutation is attributable to `request_id` + `run_id` + `sba_instance_id`; results are artifacts, not logs (I-7). |
| G-7 | **Extensible without a fork.** | New cloud, new engine, new caller and new OS family are additive changes ([AD-08](architectural-decisions.md#ad-08-provider-abstraction-via-a-fixed-contract--role-allow-list), [AD-02](architectural-decisions.md#ad-02-engine-neutral-run-contract-as-the-integration-seam)). |
| G-8 | **Same content, both engines, one repository.** | One repo, one commit, two schedulers ([AD-13](architectural-decisions.md#ad-13-this-repo-is-an-ansible-project-not-a-collection)). |

---

## 2. System Context (C4)

The platform's boundary. Everything outside is an existing enterprise capability we consume.

```
                          EXTERNAL ACTORS
      +----------+   +-----------+   +------------+
      | Requester|   | Approver  |   | Auditor /  |
      |          |   |           |   | Ops        |
      +----+-----+   +-----+-----+   +------+-----+
           |                 |                  |
           | (1) raise RITM  | (2) approve CHG  | (3) read / remediate
           v                 v                  v
   ====================================================================
   :: EXISTING ENTERPRISE PLATFORM (not built by this project) ==========
   ====================================================================
   +--------------------------------------------------------------------+
   |  ServiceNow                                                          |
   |   Service Catalog -> RITM -> Approval -> CHG -> Workflow/Task       |
   |   CMDB (CI/CI Relationship)        ITOM / Event / Notification     |
   +------------------+-------------------------+-----------------------+
                      | (4) run contract (JSON)  | (5) status callback
                      v                         v
   ====================================================================
   :: SBA PLATFORM BOUNDARY =============================================
   +--------------------------------------------------------------------+
   |                                                                    |
   |   +---------------------+        +-----------------------------+   |
   |   | Engine adapters     |        | Run-state store            |   |
   |   |  - GitHub Actions   |------->|  (object storage)          |   |
   |   |  - AAP Controller   |<-------|  context / results / locks |   |
   |   +----------+----------+        +--------------+--------------+   |
   |              |                                  |                  |
   |              v                                  v                  |
   |   +---------------------+        +-----------------------------+   |
   |   | Execution layer     |        | Configuration catalogue     |   |
   |   |  Ansible EE         |        |  (git, app/env/cloud/region |   |
   |   |  playbooks + roles  |        |   /role/os/images/policies) |   |
   |   +----------+----------+        +-----------------------------+   |
   |              |                                                     |
   |              v                                                     |
   |   +-------------------------------------------------------------+ |
   |   | Resolver  ->  Policy gate  ->  Stage 1..8  ->  Report        | |
   |   +-------------------------------------------------------------+ |
   +-------------------------------------------------------------------+
              |                        |                         |
   (6) OIDC   | (7) WinRM/SSH          | (8) HTTPS              (9) mTLS/OAuth
              v                        v                         v
   ====================================================================
   :: EXTERNAL CLOUD + MANAGEMENT PLATFORMS =============================
   ====================================================================
   +-------------+  +-------------+  +-------------+  +------------------+
   | Azure       |  | AWS         |  | GCP         |  | AD / Entra ID   |
   | (Compute,   |  | (EC2, VPC,  |  | (CE, VPC,   |  | DNS             |
   |  VNets,     |  |  S3, ...)   |  |  ...)       |  | Monitoring      |
   |  IMDS)      |  |             |  |             |  | Backup          |
   +------+------+  +------+------+  +------+------+  | Security agents |
          |                  |                  |     +------------------+
          |                  |                  |             |
          |                  |                  |     +------------------+
          |                  |                  +---->| CMDB write       |
          |                  +--------------------------->| (ServiceNow)     |
          +----------------------------------------------->|
                                                    +------------------+
   +--------------------------------------------------------------------+
   |  Approved OS Image Repository (consumed, never built here)         |
   |  Azure Compute Gallery | AWS AMI catalogue | GCP Image projects   |
   +--------------------------------------------------------------------+

   +--------------------------------------------------------------------+
   |  Source control: GitHub (this repository) + branch protection +     |
   |  required status checks + signed commits + EE registry             |
   +--------------------------------------------------------------------+
```

**Numbered flows.** (1) RITM raised. (2) Change approved in ServiceNow. (3) Audit reads CMDB
and work notes. (4) ServiceNow posts the 9-field run contract to an engine adapter. (5) Engine
posts the terminal status back. (6) Cloud identity via OIDC — no static cloud credentials
cross any boundary. (7) WinRM/SSH from the EE to the build target. (8) In-guest management
agents. (9) CMDB write over an authenticated channel.

**Explicitly outside the boundary:** image creation, landing-zone IaC, application
onboarding, autoscaling, Kubernetes. See
[§4 Out of Scope](architectural-decisions.md#4-what-is-explicitly-out-of-scope).

---

## 3. Container View (C4) — Logical Layers

Ten layers. Each has one responsibility and one owner of truth. Cross-layer calls are downward
only, plus a single return path for results.

```
  L9  CONSUMER CHANNELS      ServiceNow Catalog/Flows · GitHub Actions · AAP
      ···· future Chatbot / AI Agent / API consumers
                            ────────────────────────────────────────────
  L8  ADAPTER LAYER          Engine adapters (GHA, AAP). Dispatch, poll,
                             callback. ZERO business logic.          [AD-02, AD-21]
                            ────────────────────────────────────────────
  L7  CONTRACT & STATE       Run contract (schema-versioned JSON)
                             Run-state store: request / fingerprint /
                             context / inventory / results / locks     [AD-04, AD-20]
                            ────────────────────────────────────────────
  L6  POLICY & RESOLUTION    Resolver (pure) · naming engine · image
                             resolver · policy gate · quota/approval
                             pre-flight (read-only)                   [AD-03, AD-07,
                                                                        AD-22]
                            ────────────────────────────────────────────
  L5  LIFECYCLE ORCHESTRATOR Stage machine (1..8), serial/batch control,
                             re-entry, failure routing                 [AD-01, AD-16]
                            ────────────────────────────────────────────
  L4  PROVIDER ABSTRACTION   cloud/<provider>_vm · image/<provider>_image
                             + TagMapper (provider-shaped metadata)    [AD-08, AD-11]
                            ────────────────────────────────────────────
  L3  OS & POST-BUILD        os/<family>_baseline · domain · monitoring
                             · security_agent · vulnerability_agent ·
                             backup_agent · dns_registration ·
                             servicenow_cmdb
                            ────────────────────────────────────────────
  L2  EXECUTION ENVIRONMENT  Pinned EE image (collections, python deps,
                             OS deps) + hardened self-hosted runner    (EE doc)
                            ────────────────────────────────────────────
  L1  CLOUD & MGMT PLATFORMS  Azure / AWS / GCP · AD/Entra · DNS · CMDB
                             Approved image repositories
                            ────────────────────────────────────────────
```

**Layer rules (mechanically checkable).**

| Rule | Rationale |
|---|---|
| Dependencies point downward only. L8 never imports L5. | The adapters must be swappable; if they know about stages, GHA and AAP start diverging ([AD-01]). |
| L6 makes no cloud calls ([AD-22]). | Lowest-privilege component never holds a cloud token; enables exhaustive unit tests. |
| L6/L5 emit **data**, never secrets ([AD-15]). | The context document is safe to log and store. |
| L3 may call L1 management APIs (AD, DNS, CMDB) but never cloud *control planes*. | Separates "build the OS" from "build the infrastructure". |
| Every layer that mutates writes a result artefact ([AD-14]). | Failure of any layer is observable without log parsing. |

**The `platform/` role family (L5/L6) is not in §4's tree.** It is added because the bootstrap
requires capabilities — configuration resolution, validation, naming, policy, image selection,
state — that must live somewhere, and giving them named roles is what keeps them out of
playbooks (§31: no giant playbook) and testable in isolation. The mapping from §4 concepts to
these roles is in
[role-dependency-model.md](role-dependency-model.md#1-taxonomy).

---

## 4. Deployment View

One logical platform, three execution environments, per-cloud execution cells.

```
  ┌──────────────────────── CONTROL PLANE (per environment) ───────────────────────┐
  │                                                                              │
  │  GitHub (github.com)          AAP Cluster (dev)         AAP Cluster (nonprod)  │
  │   ├─ .github/workflows/         ├─ Automation Controller  ├─ Controller        │
  │   ├─ EE registry (GHCR)         ├─ Automation Hub        ├─ Hub              │
  │   ├─ Self-hosted runners ──┐     ├─ Projects (git SCM)    ├─ Projects         │
  │   │  ├─ dev pool          │     ├─ Credentials (external)├─ Credentials       │
  │   │  ├─ nonprod pool  ◄───┼──┐  ├─ EEs (pull from GHCR)  ├─ EEs               │
  │   │  └─ prod pool (segreg)│  │  └─ Job/Workflow Templates└─ Job/Workflow Tmpls│
  │   └─ Runners are hardened │  │                                                  │
  │                          │  │                                                  │
  │  ServiceNow              │  │  MID Server (optional, callback ingress)        │
  │   ├─ Catalog + variables │  │                                                  │
  │   ├─ Flow Designer action│──┘  (HTTPS + OAuth2 client-credentials)            │
  │   └─ Scheduled reconcile │                                                  │
  └──────────────────────────────────────────────────────────────────────────────┘
              │                                   │
              │ (OIDC / managed identity, no static keys)                         │
              v                                   v
  ┌──────────────────── EXECUTION CELLS (per cloud, per environment) ────────────┐
  │                                                                              │
  │  Runner / EE nodes            Run-state store           (Private endpoint,     │
  │  ┌──────────────────────┐     ┌──────────────────────┐    no public egress)   │
  │  │ EE image (immutable) │────>│ sba-runs/{request_id}│                       │
  │  │  - ansible-core      │     │  request.json        │                       │
  │  │  - pinned collections│     │  fingerprint.json    │                       │
  │  │  - pywinrm, boto3,   │     │  context.json        │                       │
  │  │    azure, google     │     │  inventory.json      │                       │
  │  │  - SSH/WinRM clients │     │  result.<stage>.json │                       │
  │  └───────┬──────────────┘     │  run_result.json     │                       │
  │          │ WinRM/SSH           │  lock.json           │                       │
  │          v                     └──────────────────────┘                       │
  │  ┌──────────────────┐                                                    │
  │  │  Build targets   │  Azure VM  /  EC2 instance  /  CE instance            │
  │  │  (ephemeral)     │                                                    │
  │  └──────────────────┘                                                    │
  │  Sandbox cell (dev/nonprod) ──► isolated VNet/VPC, cost-capped, auto-expire  │
  │  Production cell (prod)      ──► prod network, no auto-expire                │
  └──────────────────────────────────────────────────────────────────────────────┘
```

### 4.1 Environment separation

Isolation is enforced at five independent layers, so a mistake in one is not sufficient to
cross a boundary.

| Layer | dev | nonprod | prod |
|---|---|---|---|
| Git branch / tag | `main` | `release/*` | release tag (`v*`) |
| GitHub Environment | `dev` | `nonprod` | `prod` (**required reviewers**, deployment branch rule) |
| AAP Project branch | `main` | `release/*` | pinned release tag |
| AAP Job Template | unlocked | optional approval | approval node, restricted RBAC role |
| Runner pool | `sba-dev` | `sba-nonprod` | `sba-prod` (segregate, no shared ephemeral runners) |
| Cloud cell | sandbox VNet/VPC | nonprod network | prod network, private endpoints |
| Credentials | nonprod identities | nonprod identities | prod identities, Vault-backed, break-glass only |
| State store prefix | `sba-runs-dev` | `sba-runs-nonprod` | `sba-runs-prod` |

Engine routing per environment is [AD-09](architectural-decisions.md#ad-09-per-environment-engine-routing):
`dev`/`nonprod` → GitHub Actions, `prod` → AAP.

### 4.2 Runner isolation (rationale)

GitHub-hosted runners are not acceptable for production cloud access: they are shared,
short-lived and would require the cloud trust policy to accept GitHub's shared signing
identity broadly. Production uses **self-hosted runners**, one per environment, in a dedicated
subnet with:
- no inbound from the internet (agent-only outbound to GitHub, or an Actions ARC scale set),
- an instance identity with **no** standing cloud role (OIDC only, per-job, short TTL),
- an immutable, digest-pinned EE image on ephemeral instances,
- `--ephemeral` runners recycled after every job, so no build artifact or credential survives
  on disk,
- disk encryption and no long-lived SSH keys for the runner itself.

Full hardening baseline: [execution-environment.md](execution-environment.md#6-runner-hardening).

---

## 5. Data View

Four data classes with distinct handling. Most design errors in this kind of platform come from
treating them as one.

```
  CLASS A — REQUEST DATA            Classification: Internal
  Run contract, RITM fields, enum values. No secrets, no PII (AD-19).
  Lives: run-state store, CI/CD logs, ServiceNow work notes, AAP/GHA job detail.
  Retention: >= 7 years (aligns to CMDB lifecycle).
  +----------------------------------------------------------------+
  CLASS B — RESOLVED CONFIGURATION  Classification: Internal
  Subscription IDs, VPC/VNet IDs, subnet CIDRs, image pins, OU paths,
  security-group bindings, domain names, agent endpoints.
  Lives: run-state store only (plus the build report summary). NOT in CI
  logs in full — logs get the summary + a hash, per AD-14 + I-8.
  Retention: >= 7 years (audit), with encryption at rest.
  +----------------------------------------------------------------+
  CLASS C — CREDENTIALS            Classification: Secret
  Cloud tokens (ephemeral, OIDC), WinRM/SSH creds, domain join account,
  CMDB OAuth secret, state-store identity.
  Lives: AAP Credential store (external), GitHub OIDC trust, cloud
  identity platforms, Vault. NEVER in a contract, extra-var, workflow
  input, or the run-state store (AD-15).
  Retention: per platform policy; rotated on schedule and on role change.
  +----------------------------------------------------------------+
  CLASS D — BUILD TELEMETRY        Classification: Internal
  ansible-facts, module results, task timings, stage results, image
  versions, code SHA, EE digest, OS/patch levels, compliance scan output.
  Lives: run-state store, CI logs (redacted), SIEM, EE log store.
  Retention: >= 1 year online, then archive.
```

**Class B is the one teams get wrong.** A resolved configuration contains enough information to
reconstruct the estate topology, so it is treated as sensitive even though it contains no
credentials. Two rules follow:
1. The full `context.json` goes to the run-state store, **not** to stdout. The build report
   emits a **summary** (VM size class, image version, region, policy names) plus
   `resolved_config_hash`.
2. Cloud IDs are never hard-coded in the repository (I-8), so a repo reader cannot learn the
   estate layout from source.

### 5.1 Correlation model

One logical build, four identifiers, each with a distinct lifetime.

```
  request_id      RITM0012345        ServiceNow RITM number. Lifetime: the request record.
  change_ref      CHG0012345         ServiceNow change. Only present for governed envs.
  run_id          uuid7              One execution attempt. A retry gets a NEW run_id.
  correlation_id  uuid7              One logical build across ALL its stages and any
                                     cross-engine failover. Survives retries.
  sba_instance_id uuid4              One logical server. Survives rebuilds. [AD-05]
```

`run_id` is per-*attempt* so that a retry is distinguishable from the original — the question
"did we try this three times?" must be answerable. `correlation_id` is per-*build* so that
"which stages belong to this request?" is answerable across engines. Both are minted once at
intake and written to `fingerprint.json`; retries reuse `correlation_id` and mint a new
`run_id`. Detail: [idempotency.md](idempotency.md#2-the-sba_instance_id-golden-key).

---

## 6. Integration View

Every integration is one of four patterns. No bespoke integration is permitted.

| Pattern | Direction | Mechanism | Used for |
|---|---|---|---|
| **P1 Fire-and-observe** | in | ServiceNow → engine HTTP API; poll job status | Request dispatch, status read-back |
| **P2 Callback** | in | Engine → ServiceNow HTTPS (OAuth2 / mTLS) with signed body | Terminal + intermediate stage status |
| **P3 Cloud-native** | bidir | OIDC / managed identity / IAM role | All cloud control-plane access |
| **P4 Artifact** | out | Run-state store + CI artifacts | Results, audit, reconciliation |

**Why no long-lived inbound webhook to the engines?** Both AAP and GitHub Actions are
outbound-poll services; neither offers a general inbound webhook for job completion. Polling
is the native, supported pattern on both, and it is also *safer* — no new ingress into either
platform. Status polling is done by the ServiceNow Flow Designer action using the documented
status endpoints, with a backoff schedule, plus a callback (P2) for the terminal state to
shorten perceived latency.

**Why a ServiceNow-side reconciliation job anyway (belt and braces)?** Both the callback and
the poll can fail — a network blip, a token expiry, a Flow Designer subflow bug. A ServiceNow
scheduled job that reconciles non-terminal RITMs against the run-state store every N minutes
means the worst case is *latency*, never *a permanently stuck RITM*. This is the difference
between a self-healing process and a process that pages someone. See
[request-lifecycle.md](request-lifecycle.md#8-status-reconciliation).

**Idempotency of callbacks.** A callback may arrive twice (retry, at-least-once delivery).
Callbacks are keyed on `(request_id, stage, status, attempt_seq)` and are idempotent: applying
the same callback twice is a no-op. Signatures are verified; unsigned or mismatched callbacks
are rejected and logged, never trusted.

---

## 7. Cross-Cutting Concerns

### 7.1 Security

Full detail: [security-architecture.md](../security/security-architecture.md) and
[secret-management.md](../security/secret-management.md).

Trust boundaries:

```
  ┌─ T0 Untrusted ────────────────────────────────────────────────────┐
  │  Requester input · chatbot/AI output · ServiceNow variable values   │
  │  Validated: schema (closed enums, additionalProperties:false),     │
  │  enum membership, count bounds, change-reference presence           │
  └───────────────────────────────┬───────────────────────────────────┘
                                  │  validated contract
  ┌─ T1 Platform control plane ────┼───────────────────────────────────┐
  │  Adapters · resolver · policy gate · stage machine · run-state      │
  │  Identity: OIDC/managed identity, short TTL, no standing privilege │
  │  Never accepts a secret as input                                  │
  └───────────────────────────────┬───────────────────────────────────┘
                                  │  scoped, per-stage identity
  ┌─ T2 Cloud control plane ───────┼───────────────────────────────────┐
  │  Provisioning roles · image roles · quota/network/image pre-flight │
  │  Identity: per-environment, per-cloud, least privilege             │
  │  Writes are tag-complete and idempotent by construction             │
  └───────────────────────────────┬───────────────────────────────────┘
                                  │  WinRM/SSH, ephemeral
  ┌─ T3 Build target ──────────────┼───────────────────────────────────┐
  │  Linux/Windows baseline · domain join · agents · DNS               │
  │  Domain join uses a dedicated, non-interactively-logonable account  │
  │  Agents are allow-listed downloads from an internal source          │
  └───────────────────────────────┬───────────────────────────────────┘
                                  │  scoped integration identity
  ┌─ T4 Management platforms ──────┼───────────────────────────────────┐
  │  CMDB write · monitoring · backup · vulnerability scanning          │
  │  One identity per platform. No shared superuser.                    │
  └───────────────────────────────────────────────────────────────────┘
```

Nine distinct service identities ([AD-15](architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs)):
`svc-sba-github`, `svc-sba-aap`, `svc-sba-{azure,aws,gcp}-{env}`, `svc-sba-servicenow`,
`svc-sba-dns`, `svc-sba-domainjoin`, `svc-sba-state`, `svc-sba-cicd`. None is an enterprise
superuser. Secrets are never present in a contract, an extra-var, a workflow input, or the
run-state store.

### 7.2 Observability

| Signal | Source | Destination | Notes |
|---|---|---|---|
| Structured stage results | `result.<stage>.json` | Run-state store | Authoritative ([AD-14](architectural-decisions.md#ad-14-result-delivery-via-artifacts-never-log-scraping)) |
| Execution logs | EE stdout, redacted | CI log store + SIEM | Every line carries `request_id`/`run_id` (I-7) |
| Cloud audit | Cloud provider activity logs | SIEM | Independent source of truth for what actually changed |
| AD/DNS audit | AD event log, DNS audit | SIEM | Post-build truth |
| CMDB change | ServiceNow sys_history | ServiceNow | Business record truth |
| Metrics | Run duration, success rate, stage failure rate, orphan count | Dashboard + alert | Feeds SLOs |
| Cost | Cloud cost APIs, tagged by `sba_instance_id` | FinOps | Enables orphan remediation and showback |

The intentional design property: **no signal is scraped from another.** A failure in the
telemetry path degrades observability, never the build.

### 7.3 Compliance and audit

For any server, "what built this and what was it built from?" is answerable from three
independent records without reconstructing logs:

1. **CMDB** — `u_sba_instance_id` → business context, owner, application, change reference.
2. **Cloud tags** — `SbaInstanceId`, `SbaRunId`, `SbaConfigHash`, `ImageCatalogId`,
   `ImageVersion`, `GitSha`, `EeDigest`.
3. **Run-state store** — `context.json` (full resolved configuration) + `run_result.json`
   (full stage history) + `request.json` (the contract as received).

This triple is the audit answer to the questions auditors actually ask: *which image?* (tag +
`context.json.image`), *which code?* (tag `GitSha` + `EeDigest`), *which approval?*
(`request.json.change_reference`, resolvable in ServiceNow), *what changed on the host?*
(Stage 2–6 results plus the guest's own config-management record).

### 7.4 Scalability and quota

Three independent controls, because each addresses a different failure mode:

| Control | Prevents | Mechanism |
|---|---|---|
| `serial` per stage | Correlated mass failure | A batch size per environment/role ([C-15](architectural-decisions.md#2-requirement-conflict-register)) |
| Environment concurrency semaphore | Quota exhaustion from concurrent RITMs | CAS-based counter in the run-state store; run blocks at admission |
| Provider quota pre-flight | Provisioning failure after approval | Read-only quota check in `stage: validate`; clear `QUOTA_EXCEEDED`, not retryable |

`count` is bounded by a per-role maximum in configuration and by the sandbox's cost cap in
non-production. A request for 50 servers in `dev` is rejected by policy with an explanation,
not by a cloud API error 20 minutes later.

### 7.5 Portability

The only provider-specific content is: `configuration/clouds/<cloud>.yml` (data), and
`roles/cloud/*_vm` + `roles/image/*_image` (code). Everything else — stages, resolver, policy,
naming, tagging mapper, result model — is provider-neutral. Adding a cloud means: one config
file, two roles, one enum entry, one inventory plugin entry. The cost of adding Azure is
therefore visible and bounded, which is what makes the abstraction real rather than aspirational.

---

## 8. Architecture Decision Traceability

Requirement → decision → document. Full register:
[architectural-decisions.md](architectural-decisions.md).

| Bootstrap § | Requirement | Decisions | Primary document |
|---|---|---|---|
| 1 | Business objective, both engines, same content | AD-01, AD-02, AD-09, AD-21 | [request-lifecycle.md](request-lifecycle.md) |
| 2 | Configuration-driven, no technical inputs | AD-02, AD-19, I-1 | [configuration-resolution.md](configuration-resolution.md) |
| 3 | Layered architecture | §3 above; [AD-10](architectural-decisions.md#ad-10-no-automation-gateway-service-in-v1) | [logical-architecture.md](logical-architecture.md) |
| 4 | Repository structure | AD-12, AD-13, AD-18 | [repository-structure.md](repository-structure.md) |
| 5 | Stage separation, independent execution | AD-01, AD-04, AD-16 | [request-lifecycle.md](request-lifecycle.md) |
| 6 | Input contract | AD-02, AD-19, AD-20 | [api-contract.md](../api/api-contract.md) |
| 7 | Configuration resolution | AD-03, AD-22 | [configuration-resolution.md](configuration-resolution.md) |
| 8 | Image strategy | AD-07, I-1 | [configuration-resolution.md](configuration-resolution.md#7-image-resolution) |
| 9 | Cloud abstraction | AD-08, AD-11 | [provider-abstraction.md](provider-abstraction.md) |
| 10 | Dynamic inventory | AD-04, AD-05, AD-18 | [idempotency.md](architectural-decisions.md#ad-18-inventories-hold-control-plane-hosts-only) |
| 11 | GitHub Actions | AD-09, AD-12, AD-15 | [servicenow-github-actions.md](servicenow-github-actions.md) |
| 12 | AAP integration | AD-01, AD-09, AD-13 | [servicenow-aap.md](servicenow-aap.md) |
| 13 | AAP workflow | AD-01, AD-21 | [servicenow-aap.md](servicenow-aap.md#5-workflow-template-design) |
| 14 | ServiceNow integration, idempotency | AD-02, AD-05, AD-14, AD-19 | [api-contract.md](../api/api-contract.md) |
| 15 | Security, secrets, logging | AD-15, [C-10](architectural-decisions.md#2-requirement-conflict-register) | [security-architecture.md](../security/security-architecture.md) |
| 16 | Supply chain security | I-8, I-10 | [cicd-pipeline.md](cicd-pipeline.md#4-mandatory-checks) |
| 17 | Ansible quality | I-9, AD-08, [C-12](architectural-decisions.md#2-requirement-conflict-register) | [role-dependency-model.md](role-dependency-model.md) |
| 18 | Execution Environment | I-10, I-12 | [execution-environment.md](execution-environment.md) |
| 19 | Idempotency | AD-04, AD-05, AD-16 | [idempotency.md](idempotency.md) |
| 20 | Validation | AD-22, §4 pre-flight | [configuration-resolution.md](configuration-resolution.md#9-pre-flight-validation-stage-validate-20) |
| 21 | Failure handling | AD-14, AD-16, [C-17](architectural-decisions.md#2-requirement-conflict-register) | [failure-and-retry.md](failure-and-retry.md) |
| 22 | Retry strategy | AD-22, [failure-and-retry.md](failure-and-retry.md#4-retry-classification) | [failure-and-retry.md](failure-and-retry.md) |
| 23 | Naming convention | AD-06, [C-01](architectural-decisions.md#2-requirement-conflict-register) | [configuration-resolution.md](configuration-resolution.md#6-naming-engine) |
| 24 | Tagging | AD-11, I-3, [C-02](architectural-decisions.md#2-requirement-conflict-register) | [provider-abstraction.md](configuration-resolution.md#8-tag-resolution--tagmapper) |
| 25 | Policy as code | AD-17, AD-22 | [configuration-resolution.md](configuration-resolution.md#10-policy-gate) |
| 26 | Testing | I-5, I-11 | [testing-strategy.md](../testing/testing-strategy.md) |
| 27 | Branching | §4.1 above | [cicd-pipeline.md](cicd-pipeline.md#3-branch-and-promotion-model) |
| 28 | API design | AD-02, AD-10, AD-20 | [api-contract.md](../api/api-contract.md) |
| 29 | AI/chatbot compatibility | AD-02, AD-19, AD-20 | [api-contract.md](../api/api-contract.md#8-ai-and-chatbot-consumers) |
| 30 | Phased delivery | — | [../roadmap.md](../roadmap.md) |
| 31 | Constraints | I-1…I-12 | [architectural-decisions.md](architectural-decisions.md#3-cross-cutting-invariants) |
| 32 | Required first output | — | [docs index](../README.md) |

---

## 9. Architecture Risk Register

Risks that survive Phase 1, with the trigger that tells us a decision was wrong.

| ID | Risk | Likelihood | Impact | Mitigation / decision to revisit | Revisit trigger |
|---|---|---|---|---|---|
| R-01 | AAP is unavailable or unlicensed at the scale assumed, so prod routing is impractical | M | High | [AD-09](architectural-decisions.md#ad-09-per-environment-engine-routing) is one YAML file; GHA path is kept continuously exercised in nonprod specifically so it is a proven fallback | AAP capacity/licence decision |
| R-02 | The run-state store becomes a distributed-systems problem (concurrency, contention) | M | High | Narrow interface; CAS on blobs is sufficient for our access pattern (one writer per request; a shared counter per environment scope) | >20 concurrent runs per environment, or lock contention observed |
| R-03 | The resolver's configuration catalogue grows to hundreds of YAML files and becomes unmaintainable | M | M | Layered files with clear precedence ([configuration-resolution.md](configuration-resolution.md#4-precedence-and-merge-semantics-in-practice)); a generated catalog index; linting enforces no duplicate keys | >50 application config files |
| R-04 | Windows domain join in a fully automated pipeline is materially harder than modelled (reboots, SYSprep state, AD security policy) | **H** | High | Domain join is a *separate, independently re-runnable stage* ([AD-01](architectural-decisions.md#ad-01-single-entry-playbooks--staged-re-entry)) precisely so it can fail and be re-run without re-provisioning. Schedule reboot handling explicitly. Requires early technical validation (Phase 2 exit criteria) | First nonprod Windows build |
| R-05 | `TagMapper` drift between providers causes an inventory or policy query to silently miss servers | M | High | Single mapper, contract-tested per provider; `policy_gate` asserts tag completeness pre-flight (I-3); provider integration tests assert a round-trip query finds every created instance | First provider added |
| R-06 | GitHub Actions concurrency/runner capacity becomes the production bottleneck if routing is reversed | Low | M | Engine routing is config ([AD-09](architectural-decisions.md#ad-09-per-environment-engine-routing)); self-hosted runner pools are per-environment and independently scalable | [OQ-02](../open-questions.md#2-important--an-answer-is-needed-before-phase-4) resolved the other way |
| R-07 | Image catalogue drift: catalogue says "approved" but the underlying image is superseded or withdrawn by a security incident | M | **High** | Expiry + deprecation windows ([AD-07](architectural-decisions.md#ad-07-image-catalogue-with-pinning-and-expiry)); an emergency image withdrawal is a catalogue edit + a pre-flight image-hash check, not a code change | First security-driven image withdrawal |
| R-08 | The abstraction degrades into provider branching in orchestration content over time | M | M | `role-name[path]`+`fqcn` lint, a CI grep gate for provider module namespaces outside `roles/cloud`+`roles/image`, and the provider role contract as a review checklist | Any CI gate addition needed |
| R-09 | ServiceNow Flow Designer becomes the weak link: complex, hard to test, changes under people outside this repo | M | M | Logic lives in the platform, not the Flow ([AD-17](architectural-decisions.md#ad-17-approval-authority-stays-in-servicenow)); the Flow is a thin adapter; reconciliation job is independent of the Flow | Flow changes outside our change control |
| R-10 | Requirement creep toward Kubernetes/containers | M | M | Explicitly out of scope ([architectural-decisions.md#4-what-is-explicitly-out-of-scope)); a new build contract is required, not an extension of this one | New request type |
| R-11 | Schema consumers (chatbot, AI) drift and start sending technical fields | M | M | `additionalProperties: false` + closed enums (I-1, AD-20) reject them at the boundary with an actionable error, rather than silently accepting | First such consumer appears |
| R-12 | Short-name (15-char) collisions in the enterprise DNS/AD namespace | M | M | Separate atomic short-name counter per scope, pre-flight uniqueness check against the domain ([AD-06](architectural-decisions.md#ad-06-two-name-model-short-netbios-name--long-fqdn)); documented exception process | Collision rate above threshold in nonprod |
| R-13 | `count: N` runs leave partial server sets on failure, and the CMDB shows fewer servers than the RITM requested | M | M | Per-host results ([AD-14](architectural-decisions.md#ad-14-result-delivery-via-artifacts-never-log-scraping)) roll up to `PARTIAL`; CMDB registers what exists; the RITM is not marked complete | First PARTIAL run in prod |
| R-14 | Cost of the platform itself (runners, EEs, state storage) is unbudgeted | M | L | Per-environment resource tags and a monthly cost report using the same `TagMapper` metadata; platform budget is a named line in the roadmap | Monthly FinOps review |
| R-15 | Enterprise landing zones are not ready in all three clouds, so the catalogue is unpopulatable | M | M | Catalogue is data-only; partial population is valid — a cloud with no entries simply fails the pre-flight with `NO_APPROVED_CONFIGURATION` and an actionable message | Cloud onboarding schedule |

---

## 10. Next

- Component responsibilities and the full responsibility matrix: [logical-architecture.md](logical-architecture.md)
- Stage-by-stage request lifecycle and status model: [request-lifecycle.md](request-lifecycle.md)
- Resolution hierarchy and merge semantics: [configuration-resolution.md](configuration-resolution.md)
- Delivery plan and phase exit criteria: [../roadmap.md](../roadmap.md)
