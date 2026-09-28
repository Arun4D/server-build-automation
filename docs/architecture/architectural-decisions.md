# Architectural Decisions and Requirement Conflict Register

Status: **Phase 1 — Proposed**
Scope: Multi-Cloud Server Build Automation Platform (`server-build-automation`)

This document is the authoritative record of *why* the platform is shaped the way it is.
Every decision below either resolves an ambiguity in `PROJECT_BOOTSTRAP.md`, or resolves a
conflict **between** two requirements in it. Conflicts are listed in
[§2 Requirement Conflict Register](#2-requirement-conflict-register) and are the highest-value
output of Phase 1 — several of them are hard platform limits (DNS, GCP, Windows, GitHub
semantics) that cannot be engineered away, only designed around.

---

## 1. Decision Register

Status values: `PROPOSED` (awaiting approval) · `ACCEPTED` · `SUPERSEDED` · `REJECTED`

| ID | Title | Status | Bootstrap ref | Reversibility |
|---|---|---|---|---|
| [AD-01](#ad-01-single-entry-playbooks--staged-re-entry) | Single entry playbooks + staged re-entry | PROPOSED | §5, §12, §13 | Medium |
| [AD-02](#ad-02-engine-neutral-run-contract-as-the-integration-seam) | Engine-neutral run contract as the integration seam | PROPOSED | §11, §12, §28, §29 | Low |
| [AD-03](#ad-03-configuration-resolver-is-a-python-library-not-jinja) | Config resolver is a Python library, not Jinja | PROPOSED | §7, §9 | Medium |
| [AD-04](#ad-04-run-state-store-is-the-execution-source-of-truth) | Run-state store is the execution source of truth | PROPOSED | §10, §14, §19 | Medium |
| [AD-05](#ad-05-sba_instance_id-is-the-golden-join-key) | `sba_instance_id` is the golden join key | PROPOSED | §10, §14, §24 | High |
| [AD-06](#ad-06-two-name-model-short-netbios-name--long-fqdn) | Two-name model: short NetBIOS name + long FQDN | PROPOSED | §23 | Low |
| [AD-07](#ad-07-image-catalogue-with-pinning-and-expiry) | Image catalogue with pinning and expiry | PROPOSED | §6, §8, §25 | Medium |
| [AD-08](#ad-08-provider-abstraction-via-a-fixed-contract--role-allow-list) | Provider abstraction via fixed contract + role allow-list | PROPOSED | §9 | Low |
| [AD-09](architectural-decisions.md#ad-09-per-environment-engine-routing) | Per-environment engine routing | PROPOSED | §11, §12 | **High** |
| [AD-10](architectural-decisions.md#ad-10-no-automation-gateway-service-in-v1) | No Automation Gateway service in v1 | PROPOSED | §3, §28 | **High** |
| [AD-11](#ad-11-gcp-labels-for-indexable-subset-annotations-for-full-metadata) | GCP: labels for indexable subset, annotations for full metadata | PROPOSED | §24 | Low |
| [AD-12](#ad-12-canonical-workflows-live-in-githubworkflows) | Canonical workflows live in `.github/workflows` | PROPOSED | §4, §11 | **High** |
| [AD-13](#ad-13-this-repo-is-an-ansible-project-not-a-collection) | This repo is an Ansible *Project*, not a Collection | PROPOSED | §4 | **High** |
| [AD-14](#ad-14-result-delivery-via-artifacts-never-log-scraping) | Result delivery via artifacts, never log scraping | PROPOSED | §14, §21 | Medium |
| [AD-15](#ad-15-no-secrets-in-extra_vars--workflow-inputs) | No secrets in `extra_vars` / workflow inputs | PROPOSED | §12, §15 | Low |
| [AD-16](#ad-16-forward-fix-over-auto-destroy) | Forward-fix over auto-destroy | PROPOSED | §5, §21 | Medium |
| [AD-17](#ad-17-approval-authority-stays-in-servicenow) | Approval authority stays in ServiceNow | PROPOSED | §1, §25 | Medium |
| [AD-18](#ad-18-inventories-hold-control-plane-hosts-only) | Inventories hold control-plane hosts only | PROPOSED | §4, §10 | Medium |
| [AD-19](#ad-19-derived-fields-are-resolved-server-side-by-servicenow) | Derived fields resolved server-side by ServiceNow | PROPOSED | §6, §14 | Medium |
| [AD-20](#ad-20-additive-schema-versioning-only) | Additive schema versioning only | PROPOSED | §28, §29 | Low |
| [AD-21](#ad-21-single-active-engine-per-run) | Single active engine per run | PROPOSED | §11, §12 | Medium |
| [AD-22](#ad-22-resolver-is-read-only-and-side-effect-free) | Resolver is read-only and side-effect free | PROPOSED | §7 | Low |

---

### AD-01: Single entry playbooks + staged re-entry

**Decision.** All orchestration logic lives in exactly **one** entry playbook per lifecycle
family. Stages are selected at runtime by a `stage` variable, not by separate playbooks.

```
playbooks/
  server_build.yml     <- the single entry point; --stage <name> or --stages a,b,c
  server_destroy.yml
  server_validate.yml
```

`PROJECT_BOOTSTRAP.md` §5 mandates "Each stage must be independently executable" and §31
forbids "one giant playbook". These are reconciled by *parameterised re-entry*:

```bash
ansible-playbook playbooks/server_build.yml -e @run_context.json -e '{"stage":"provision"}'
ansible-playbook playbooks/server_build.yml -e @run_context.json -e '{"stage":"domain_join"}'
ansible-playbook playbooks/server_build.yml -e @run_context.json -e '{"stage":"cmdb"}'
```

The entry playbook delegates each stage to a role via `ansible.builtin.import_role`
(statically listed so ansible-lint and `--list-tasks` stay meaningful) with a
`when: sba_current_stage in ...` guard.

**Why.**
- §31 says "Do not duplicate automation logic between GitHub and AAP" (§12 restates it).
  The only way to guarantee that is to have exactly one copy of the orchestration. A
  GitHub workflow and an AAP Workflow Template that both express the same 8-stage sequence
  *are* duplication, and they will drift.
- A monolith-with-tags is the failure mode §31 warns about. Parameterised stage dispatch is
  neither: it is a single entry point with a bounded, statically-enumerable stage table.
- Stage re-entry needs durable state anyway (AD-04), so a stage-scoped invocation is the
  natural unit of resumption.

**Consequences.**
- One GitHub workflow file and one AAP Job Template can drive the entire lifecycle.
- Re-running one stage does not require re-running earlier stages (state comes from AD-04).
- `ansible-playbook --list-tags` and a generated `docs` stage table are the two introspection
  surfaces used by the ServiceNow integration.

**Alternatives rejected.**
- *Separate playbook per stage* — duplicates cross-stage plumbing (state load/save, guards,
  reporting) into 8 files. Rejected on §31.
- *AAP Workflow Template as the canonical sequence* — makes AAP mandatory and gives up
  GitHub Actions, contradicting §1.5.
- *Ansible "Workflow" plugin* — not portable to `ansible-playbook` in GitHub Actions.

---

### AD-02: Engine-neutral run contract as the integration seam

**Decision.** The only thing that crosses into the platform is a **run contract** — a
versioned JSON document matching `schemas/server_request.schema.json`. It contains business
inputs only. Everything technical is derived *inside* the platform.

```
ServiceNow ─┐
Chatbot    ─┤
AI Agent   ─┼─▶ [Run Contract JSON] ─▶ Engine adapter (GHA | AAP) ─▶ server_build.yml
Human API  ─┘                                  (no logic lives here)
```

**Why.** §29 requires that an AI agent can produce a request but can never execute Ansible.
The only way to guarantee that structurally is to make the *entire* input surface a schema
with no free-text and no arbitrary-variables escape hatch. If the contract is the seam, then
"the AI can only generate a structured request" is a property of the type system, not a
policy statement.

**Consequences.**
- A future `POST /server/build` HTTP endpoint (§28) is a transport adapter for the same
  contract. See [AD-10](architectural-decisions.md#ad-10-no-automation-gateway-service-in-v1).
- Engine adapters are ~50 lines each and contain no business logic.
- Adding a new caller (chatbot, AI agent, Terraform module, cost-tooling) requires no
  platform change.

---

### AD-03: Configuration resolver is a Python library, not Jinja

**Decision.** `scripts/lib/sba_resolver/` is a pure-Python, dependency-light, deterministic
library exposed as a CLI (`scripts/resolve_configuration.py`). Ansible consumes its output;
it never re-implements resolution in Jinja.

**Why.**
- §9 explicitly: "Prefer clean provider abstraction over excessive Jinja complexity."
  §7 requires a resolution *hierarchy* with conflict detection and safe failure. Expressing
  an 8-level deep merge with conflict semantics, provenance tracking and unit tests in Jinja
  filters is not maintainable and not reviewable.
- §26 requires unit tests. Python gives table-driven tests; Jinja gives assertion failures
  in an Ansible run.
- §6 requires schema validation of the *output*. JSON Schema validation of a Python dict is
  trivial; of an Ansible-registered result it is awkward.
- The same library must be callable from GitHub Actions, from an AAP job, and from a future
  HTTP API. Only Python satisfies all three.

**Constraint on the resolver.**
- It is **pure**: given (request, configuration catalogue) it returns the same
  `resolved_configuration` every time. No clock-dependent decisions except image expiry,
  which is an explicit input (`as_of`).
- It performs **no I/O to cloud providers** (AD-22). Quota and image-existence checks are a
  separate pre-flight stage with read-only cloud credentials.
- Every resolved leaf records its **provenance** (which config file + key produced it). This
  is what makes a policy rejection explainable to a requester.

**Alternatives rejected.**
- *`group_vars` deep merge + `combine`* — has no provenance, no conflict policy, no schema
  validation, and precedence between `all/` and `azure/` subdirs is implicit.
- *Ansible Dynamic Group Vars via a lookup plugin* — still Jinja underneath.
- *OPA / policy engine* — explicitly deferred; see
  [OQ-05](../open-questions.md#3-design--an-answer-is-needed-before-the-relevant-phase). The resolver emits the input a
  policy engine would consume, so this is not a fork in the road.

---

### AD-04: Run-state store is the execution source of truth

**Decision.** All cross-stage, cross-run execution state lives in a **run-state store**:
an object-store-backed key/value namespace, one prefix per `request_id`.

```
sba-runs/{request_id}/
  request.json          immutable intake (the run contract as received)
  fingerprint.json      sha256 of the canonicalised contract + config catalog version
  context.json          resolved configuration + allocations (names, ids, image pin)
  inventory.json        generated static inventory for the run's targets
  result.<stage>.json   per-stage structured result
  run_result.json       rollup across stages and hosts
  lock.json             conditional-write lock (ETag / generation-match)
```

**Why.** §5 requires each stage to be independently executable. That is only possible if a
stage can reconstruct everything it needs without re-running earlier stages. §14 requires
idempotency across repeated ServiceNow requests, which requires a durable record of
`request_id → run`. §19 requires idempotency. All three point at the same requirement.

**Why object storage and not a database.**
- No new stateful service to operate, patch, back up and HA.
- Objects are immutable-per-write and versionable; conditional writes (`If-Match`, S3
  `If-None-Match`, GCS `generationMatch`) give us compare-and-swap for the *name sequence
  counter* and the *environment concurrency semaphore* without a lock service.
- The same store works on all three clouds (Azure Blob / S3 / GCS) behind one interface.

**Interface.** `RunStateStore` with methods `put`, `get`, `list`, `cas` (compare-and-swap).
Backends: Azure Blob, S3, GCS. Selection is per-environment, matching the target cloud, with
a private endpoint and no public egress.

**Consequences.**
- The store is a **security-relevant** component: it contains resolved infrastructure design
  (subnets, image IDs, OU paths). It is encrypted at rest, access-logged, and readable only
  by the platform's execution identity.
- Backends are not interchangeable at the byte level, so tests use an in-memory
  implementation (`tests/fixtures`) — this is why the interface is narrow.
- A stale/abandoned run is garbage-collectable by TTL, and the GC job is itself a platform
  responsibility (documented in the operations runbook, not implemented in Phase 1).

---

### AD-05: `sba_instance_id` is the golden join key

**Decision.** Every provisioned server carries a platform-assigned `sba_instance_id`
(UUIDv4, minted at allocation time). It is the primary key across **all** systems.

| System | Key |
|---|---|
| Run-state store | `sba_instance_id` (indexed) |
| Cloud tags/annotations | `SbaInstanceId` |
| ServiceNow CMDB | dedicated `u_sba_instance_id` field on the CI record |
| Ansible inventory | `ansible_host` group var + `sba_instance_id` host var |
| Build/audit logs | `sba_instance_id` in every log record |

**Why.** §14 idempotency, §10 dynamic inventory, §24 tagging and Stage 7 (CMDB) all need a
join key. The obvious candidates all fail:
- *Cloud resource ID* changes on every rebuild and is provider-specific; it is useless for
  cross-provider correlation.
- *Hostname* is deterministic but the naming engine (§23) may be revised, and a rename
  breaks the join.
- *`request_id`* is one-to-many with servers (`count: 2`).
- *FQDN* can change during DNS registration and is not unique across environments.

An opaque platform-owned UUID is stable across provider migrations, rebuilds and renames, and
is exactly what an enterprise CMDB wants as its automation lineage field.

**Consequences.**
- Rebuilds are supported: same logical server, new cloud resource ID, stable
  `sba_instance_id`, CMDB record updated in place.
- Idempotency at the *host* level (not just request level) falls out naturally.
- A "find everything this platform did" query becomes a single tag search per cloud.

---

### AD-06: Two-name model: short NetBIOS name + long FQDN

**Decision.** Each instance gets two names:

| Attribute | Constraint | Example |
|---|---|---|
| `short_name` | `[a-z0-9-]{1,15}`, **must not end in a hyphen** | `pypa001` |
| `fqdn` | RFC 1123 label ≤ 63, total ≤ 253 | `pay-prod-app-ams-001.corp.example.com` |

`short_name` is the Windows computer name / Linux `hostname` and the DNS A-record owner name
in the *Windows* DNS zones. `fqdn` is the primary record in the *internal Unix/DNS-automation*
zone and the value used in CMDB and monitoring.

**Why — this is a hard conflict in the bootstrap.**

§23 specifies the naming pattern:

```text
<application>-<environment>-<role>-<region>-<sequence>
pay-prod-app-ams-001          <- 19 characters
```

`pay-prod-app-ams-001` is **19 characters**. The Windows NetBIOS computer name limit is
**15 characters** (SAM account name, `samAccountName`). A 19-character computer name cannot
domain-join to Active Directory. Since Stage 4 (domain join) is mandatory and Windows is a
first-class target, §23's literal example is not implementable for Windows.

Compounding constraints that the pattern must also survive:

| Constraint | Limit |
|---|---|
| Windows SAM account name | 15 |
| Windows hostname | 15 |
| Linux hostname | 63 (deprecated 64) |
| DNS label | 63 |
| Azure VM name | 64 (Windows computer name + `.` + suffix ≤ 15 for AD) |
| Azure computer name / AD join | must be ≤ 15 |
| GCP instance name | 63 (RFC 1035) |
| EC2 `Name` tag | 255 (no limit) |

**Resolution.** The *long* form is preserved verbatim for `fqdn`, tracing, reporting and
CMDB. The *short* form is derived from the same tokens by a documented, deterministic
compaction algorithm (see `docs/architecture/configuration-resolution.md` §Naming Engine) and
**fails the policy gate** if it cannot be produced unambiguously. Users cannot override
either name (§23); a documented platform-team exception process exists for collisions.

**Consequences.**
- The naming engine must reserve the short-name namespace per `{env, app, role, region}`
  scope with a separate atomic counter, because short names are far scarcer than long names.
- The resolver must validate short-name uniqueness across the *whole* enterprise domain, not
  just per resource group.

---

### AD-07: Image catalogue with pinning and expiry

**Decision.** Images are described by an **abstract, platform-owned catalogue entry**, never
by a requester-supplied ID. At resolution time the catalogue entry is converted into a
**concrete, pinned** image reference which is frozen into `context.json` for the life of the
run.

```yaml
# configuration/images/catalog.yml
- id: win-2025-enterprise
  os_family: windows
  os_version: "2025"
  classification: enterprise
  approval_status: approved
  baseline: cis-windows-2025.1
  published_at: "2026-03-01"
  expires_at: "2026-09-01"
  providers:
    azure: { type: SharedImageVersion, gallery: <org>_images, image: windows-2025, version: "12.3" }
    aws:   { type: ami, id: "ami-0<...>" }     # resolved/refreshed by the image pipeline
    gcp:   { type: image, project: <img-proj>, family: windows-2025-ent }
```

**Why.** §8 forbids arbitrary image IDs from requesters and requires approval metadata. But
the catalogue alone is not enough: between resolution and provisioning the catalogue may
change, and "Windows 2025 approved" is not a reproducible build input. Pinning makes the run
reproducible and auditable — the exact image version used is answerable for the life of the
asset, which is what auditors ask.

**Expiry semantics.**
- `expires_at` in the past ⇒ the catalogue entry is **not selectable** by the resolver
  (hard failure, `error_code: IMAGE_EXPIRED`, not retryable).
- An already-pinned run **may** complete using an image that has since expired — expiry
  gates *new* selection, not in-flight work. Otherwise a 40-minute Windows build could be
  failed at minute 39 for a reason unrelated to it.
- Deprecated-but-not-expired entries emit a `WARNING` and appear in the build report.

**Why AWS needs special handling.** AMI IDs are immutable and effectively opaque; a
"catalogue" of AMIs therefore must be *maintained* (by the image pipeline, out of scope for
this repo) or resolved at runtime by tag query. Decision: AWS catalogue entries may specify
either an explicit `id` (pinned, preferred for reproducibility) or a `tag_query`, with
`tag_query` resolution recorded in `context.json` with the resolved AMI and a timestamp.
Azure Shared Image Versions and GCP image families resolve cleanly to stable references.

---

### AD-08: Provider abstraction via a fixed contract + role allow-list

**Decision.** §9's dynamic `include_role: name: "cloud/{{ cloud_provider }}_{{ resource_type }}"`
is **replaced** with a static `import_role` list guarded by an allow-list.

```yaml
# roles/platform/resolve_configuration/tasks/main.yml (shape, Phase 4)
- name: Dispatch to the approved provider role
  ansible.builtin.import_role:
    name: "cloud/{{ sba_cloud_role }}"        # one of the 3 literals below, never user text
  when: sba_enabled

# sba_cloud_role is set by the resolver, from a closed enum:
#   azure -> azure_vm   |  aws -> aws_ec2   |  gcp -> gcp_compute
```

**Why.** Two reasons, one correctness and one security.

1. *Correctness.* `include_role` with a Jinja-interpolated name resolves at runtime, so
   `--list-tasks`, ansible-lint's `syntax-check` and static analysis all degrade, and a typo
   becomes a runtime failure deep into a production run.
2. *Security.* A dynamic role name is a **code-loading primitive**. If `cloud_provider` were
   ever attacker-influenced (an AI agent, a compromised ServiceNow field, a future API
   consumer that under-validates), `name: "cloud/{{ x }}"` becomes arbitrary local role
   inclusion. The fix is structural: the resolver emits a *closed enum member* from a
   hard-coded map, and a policy gate asserts membership before any dispatch. The value that
   reaches the role name is never free text.

**The provider role contract** (required inputs / required outputs) is specified in
[role-dependency-model.md](role-dependency-model.md#3-the-provider-role-contract).
Abstract operations: `provision`, `get`, `validate`, `destroy`, `tag`, plus `get_image` on the
image roles.

**Consequence.** Adding a 4th cloud is a new role + one enum entry + resolver mapping. No
change to any orchestration content.

---

### AD-09: Per-environment engine routing

**Decision.** Both engines are supported simultaneously, and **which engine runs a given
environment is configuration, not code**:

```yaml
# configuration/routing/engine_routing.yml
routing:
  dev:     { engine: github, github_workflow: server-build.yml,  aap_workflow: null }
  nonprod: { engine: github, github_workflow: server-build.yml,  aap_workflow: null }
  prod:    { engine: aap,    github_workflow: null,               aap_workflow: Server Build - PROD }
```

Recommended **default**, and the reason for it:

| Environment | Engine | Rationale |
|---|---|---|
| `dev` | GitHub Actions | Fast feedback, PR-native, no queue. Sandbox cloud only. |
| `nonprod` | GitHub Actions | Validates the GitHub path at volume. Sandbox cloud only. |
| `prod` | AAP | Central execution, Execution Environment, credential store, RBAC, job slicing, scheduler, long-term audit retention. |

**Why this asymmetry is right.** §1 requires *both* paths to be supported. Making the
*same* engine the default for prod and nonprod would leave the other path unexercised in a
setting where it matters. Splitting them means both paths are continuously load-bearing, and
a defect in either is discovered in nonprod before prod depends on it. It also matches where
each engine's control features are strongest: AAP's credential isolation and audit are
decisive for prod, while GHA's PR integration is decisive for the build pipeline.

**This is the single most reversible decision in the register** — it is one YAML file. It is
also the decision most likely to be reversed by the platform owner, so it is flagged
`Reversibility: High` and raised as [OQ-02](../open-questions.md#2-important--an-answer-is-needed-before-phase-4).

**Constraints that hold regardless of routing** (AD-21):
- Exactly **one** engine is active for a given run. Never AAP-dispatches-to-GitHub or
  GHA-dispatches-to-AAP. A run has one executor for its whole lifetime.
- Both engines execute the *same commit SHA* of this repository. The resolved image tag is
  recorded in `context.json` and in the ServiceNow work note, so it is always answerable
  which code built a server.

---

### AD-10: No Automation Gateway service in v1

**Decision.** §3 places an "Automation Gateway / Orchestration" box between ServiceNow and
the engines. In v1 that box is **not a deployed service**. It is a *logical* role fulfilled
by the pair of thin engine adapters plus the ServiceNow-side flow.

```
v1 (no new service)                        v2 (optional, if needed)
----------------------                     --------------------------------
ServiceNow                                ServiceNow
   |  POST run contract                       |  POST run contract
   v                                          v
GHA workflow_dispatch      or             [Automation Gateway]  <- stateless, real service
AAP  POST /jobs/.../        adapters           |  dispatch, route, RBAC, rate-limit
   |                                          +-> GHA
   v                                          +-> AAP
server_build.yml  (identical)              [Run State Store]  (already exists in v1)
```

**Why.** §3 is a *logical* architecture diagram; §11 and §12 describe ServiceNow calling
GitHub Actions and AAP **directly**. §28 then asks for an HTTP API callable by ServiceNow,
GitHub Actions, AAP, a chatbot and an AI agent simultaneously.

Reconciling all three honestly:
- §11/§12 (direct calls) need **no new component** and work today.
- §28's *contract* is fully realised by the run contract of AD-02.
- §28's *HTTP surface* is only needed when a caller cannot speak either engine API — i.e. the
  future chatbot/AI agent, and possibly third parties.

Building a stateful gateway now to serve two callers (ServiceNow + GitHub) that can already
call natively is premature: it adds an on-call surface, an HA/DR obligation, an auth tier, and
a place for the run-state store to be split in half — before we know the real access patterns.

**Revisit trigger (explicit).** Build the gateway when *any* of these becomes true:
1. A chatbot/AI agent consumer goes live.
2. More than ~5 distinct callers exist.
3. Central rate-limiting or a cross-engine concurrency semaphore is required and cannot be
   hosted in the run-state store.
4. A compliance requirement demands a single network entry point for all automation.

The run contract of AD-02 is deliberately the *same* shape the gateway would accept, so
adding it later is additive and non-breaking.

---

### AD-11: GCP: labels for indexable subset, annotations for full metadata

**Decision.** §24's 12 mandatory tags are applied differently on GCP.

```
GCP labels     (≤63 chars/value, 64 max, indexed, used for filtering and policy):
    sba_request_id, sba_instance_id, app, env, role, region,
    managed_by, lifecycle_stage, data_classification

GCP annotations (no practical length limit, not indexed, full metadata):
    Application, Environment, ServerRole, Owner, CostCenter, BusinessUnit,
    ManagedBy, AutomationPlatform, ServiceNowRequest, ChangeRequest,
    DataClassification, Criticality, CreatedBy, ImageCatalogId, ImageVersion,
    ResolvedConfigHash, RunId, CorrelationId
```

**Why — this is a hard platform conflict, not a preference.**

| Cloud | Tag/label key limit | Value limit | Count limit |
|---|---|---|---|
| Azure | 512 | 256 | 50 tags |
| AWS | 128 | 256 | 50 tags |
| **GCP** | **63** | **63** | **64 labels** + annotations |

A 64-character value limit plus a 63-character key limit means:
- `ChangeRequest` is 14 characters — fits as a key. But a GCP label *key* must be lowercase
  letters, digits, `-` and `_` (no uppercase), so `ServiceNowRequest` and `CostCenter` are
  **invalid GCP label keys** and must be renamed to `servicenow_request` / `cost_center`.
- A 12-field tag set with 8 of them being metadata-only does not belong in labels at all;
  labels exist to be *queried*. Every label is billed as part of the instance and slows
  `gcloud --filter` if over-used.
- GCP Compute Engine is also stricter about when labels can be changed (adding/removing
  labels requires the instance to be stopped) — so labels must be correct **at create time**,
  not patched later. That makes the "full metadata in labels" approach actively harmful.

**Consequences.**
- A `TagMapper` in the resolver produces a provider-shaped tag set, so no role ever
  hand-builds tags. `configuration/clouds/gcp.yml` declares the label/annotation split.
- The 12 mandatory §24 tags are all present on every provider — in the provider's *correct*
  namespace. The *mandate* is met; the *mechanism* differs.
- Tag-driven dynamic inventory must query labels **and** annotations on GCP; documented in
  `docs/architecture/cloud/gcp.md`.

---

### AD-12: Canonical workflows live in `.github/workflows`

**Decision.** §4 places workflows in `automation/github/workflows/`. GitHub Actions **only
discovers** workflow files in `.github/workflows/` at the repository root. Files elsewhere are
inert.

```
.github/workflows/              <- CANONICAL. The only place GitHub will run from.
  server-build.yml
  server-destroy.yml
  server-validate.yml
  post-build.yml
  ci-lint.yml
  ee-build.yml

automation/github/              <- supporting content, NOT workflow definitions
  composite/                    reusable composite actions (setup-python, resolve-config, ...)
  runner-config/                self-hosted runner labels & hardening baseline
  README.md                     maps each workflow to its stage + run-contract inputs
```

**Consequences.**
- The §4 listing is corrected in
  [repository-structure.md](repository-structure.md); `.github/workflows/` is added to the
  canonical tree.
- `automation/github/` is repurposed rather than deleted, so composite actions stay testable
  and versioned with the repo.
- Only one copy of each workflow exists, which is required for AD-21 (no duplicate run path).

**Related hard constraint (GitHub semantics).** Both triggering mechanisms require the
workflow file to exist on the **default branch**:
- `POST /repos/{o}/{r}/actions/workflows/{wf}/dispatches` (`workflow_dispatch`) — looks up
  the workflow on the default branch.
- `POST /repos/{o}/{r}/dispatches` (`repository_dispatch`) — same.

**Consequence for the ServiceNow→GitHub flow.** The engine adapter must *always* dispatch the
`main` (or a pinned release tag's) copy of the workflow, and the *content* to run is
supplied as **inputs** (a `config_ref`/`ref` input for the code to check out, plus the run
contract). The adapter must never try to dispatch a workflow that only exists on a feature
branch. See [servicenow-github-actions.md](servicenow-github-actions.md#5-repository-layout-and-the-default-branch-constraint).

---

### AD-13: This repo is an Ansible *Project*, not a Collection

**Decision.** §4 lists `galaxy.yml` at the repository root. A root `galaxy.yml` declares the
repository to be an **Ansible Collection**, which imposes a hard `namespace.collection_name`
directory layout, `meta/runtime.yml` action-group requirements, and a build/publish
lifecycle — none of which the specified tree is shaped for.

**Decision: do not create `galaxy.yml`.** This repository is an Ansible **Project** (a
role library + playbooks + configuration), consumed by AAP via a **Project** with a Git SCM
source, and by GitHub Actions via a plain checkout. Roles live under `roles/` in the classic
project layout exactly as §4 specifies.

**Consequences.**
- AAP consumes it as a Project with `scm_type: git` — a first-class, supported pattern.
- Roles are not individually consumable by other teams via Galaxy. If per-role reuse becomes
  a requirement, the roles are extracted into a Collection at that point (roles move to
  `roles/collections/<ns>/<name>/roles/...`, a mechanical move). Not a fork in the road.
- Recorded because §4 asked for the file. Flagged as a resolved conflict, not an oversight.

---

### AD-14: Result delivery via artifacts, never log scraping

**Decision.** Structured results are delivered as **artifacts**, not parsed from console output.

| Engine | Transport |
|---|---|
| GitHub Actions | `run_result.json` uploaded via `actions/upload-artifact`; job conclusion from exit code; ServiceNow reads status from the API or the callback |
| AAP | `run_result.json` written to the run-state store by the last role, plus the AAP job/unified-job status API |

**Why.** Log scraping is the single most common source of silent breakage in CI-driven Ansible:
a `--diff` line, a module deprecation warning or a colour-code change silently breaks a
regex, and because it fails *after* the infrastructure is built, the failure surfaces as
"ServiceNow says failed, servers exist". Artifact-based results cannot be broken by a log
format change, and the artifact is itself the audit record.

**Consequences.**
- `ansible.builtin.default` callback with a restricted `stdout_callback` whitelist.
- A mandatory final task in every stage writes `result.<stage>.json` before the playbook
  exits, and the playbook exits non-zero if any host's status is not `SUCCESS`.
- `no_log` redaction (§15) is a defence-in-depth measure, not the primary secret-protection
  mechanism — the primary mechanism is AD-15.

---

### AD-15: No secrets in `extra_vars` / workflow inputs

**Decision.** No credential, token, password, key or connection string is ever passed as an
Ansible extra-var, a GitHub Actions input, a workflow `env:` value, or a ServiceNow field.

| Need | Mechanism |
|---|---|
| Cloud control plane (GHA) | GitHub OIDC → short-lived cloud token (`azure/login`, `aws-actions/configure-aws-credentials`, `google-github-actions/auth`) |
| Cloud control plane (AAP) | AAP Credential of type cloud / kubernetes / or an OIDC-backed credential |
| WinRM / SSH to target | AAP Credential, or SSH cert issued to the runner; passed via `ansible_password` from the credential store |
| Domain join | AAP Credential with the domain join account; `no_log: true` |
| CMDB write | AAP Credential (OAuth / basic for a scoped integration user) |
| Run-state store | Workload identity / managed identity; no static key where the cloud supports it |

**Why.** This is a real and frequently-exploited leak, and it is worth being blunt about it:
- **Ansible extra-vars are printed in full in the AAP job invocation, in the AWX/Tower
  audit log, and in the job detail page**, and are readable by anyone with read access to that
  job — a much wider audience than the people who should see the secret.
- **GitHub Actions inputs and `env:` are visible in the workflow run page** and in
  `GITHUB_ENV`, to anyone with read access to Actions, plus they appear in the fork-PR threat
  model if the workflow is ever made reusable across untrusted repos.
- Secrets in GitHub Secrets are *masked in logs*; secrets in **inputs are not** — they are
  rendered verbatim.

**Consequences.**
- Run contracts are safe to log in full. This is why AD-02 can promise a fully auditable
  contract.
- A stage that needs a credential declares **which** credential, by name, in a
  non-secret allow-list mapping (`roles/platform/*/defaults/main.yml`), and the engine binds
  it. The mapping is configuration; the value is not in the repository.
- Ansible Vault is **not** used for anything committed to this repository (AD: "Vault only
  where appropriate" in §15 — we define "appropriate" as *nothing in git*). Vault is available
  for local developer scratch space and is git-ignored.

---

### AD-16: Forward-fix over auto-destroy

**Decision.** On a post-provisioning stage failure, the platform does **not** automatically
destroy the already-provisioned infrastructure.

```
Stage 1 Provision   ── FAILED ──▶ auto-destroy permitted (nothing valuable exists yet)
Stage 4 Domain join ── FAILED ──▶ PARTIAL. Infrastructure retained.
                                 ServiceNow RITM -> "Manual Attention".
                                 Remediation: re-run stage 4 only (idempotent).
```

| Environment | On post-provision failure |
|---|---|
| `dev` | optional auto-destroy, controlled by `on_failure: destroy` in env config (default `retain`) |
| `nonprod` | retain; auto-destroy requires explicit policy flag |
| `prod` | retain. Destroy requires a **separate, approved** ServiceNow request. |

**Why.** Auto-destroy on post-provision failure is a cost optimisation that becomes a data-loss
and audit problem: Stage 4–7 include domain join, DNS and CMDB registration. Destroying at
Stage 6 leaves orphaned AD computer objects, orphaned DNS records and a CMDB record pointing at
nothing. Those orphans are *more* expensive to clean up than a stopped VM, and they are
invisible. Cost is controlled by the daily orphan-reporting job instead, which is auditable.

Auto-destroy **is** permitted when Stage 1 itself fails, because a partially-created VM
(invalid NIC, failed extension) is genuinely junk.

**Consequence.** §21's `PARTIAL` status is a first-class outcome, not an edge case. The
ServiceNow flow must have a "Manual Attention" branch — see
[request-lifecycle.md](request-lifecycle.md#5-failure-branches).

---

### AD-17: Approval authority stays in ServiceNow

**Decision.** The platform **trusts ServiceNow as the authorisation boundary** and does not
re-implement approval workflows. Policy evaluation in the platform is limited to *technical and
organisational* policy (approved clouds/regions/OS/images/sizes, PROD change requirement,
naming, tagging, network rules).

**Why.** Duplicating approval logic would create two approval systems that disagree. The
platform's job is to make the *technical* consequences of an approved request deterministic and
enforceable. §25's list is entirely technical/organisational, with one governance item
("Production restrictions", "Approval missing" in §22's non-retryable list).

**Mechanism for the one case that matters.** For `environment: PROD` the run contract must
carry a non-empty `change_reference`. Optionally, where
`policies.production.verify_approval_with_servicenow: true`, the validation stage calls a
read-only ServiceNow endpoint to confirm the change is in an approved/implementing state
before provisioning. This is defence in depth for the highest-blast-radius path, is off by
default, and costs one read-only call.

**Consequence.** The platform never needs to see approver identity for its own decisions, so
the run contract stays minimal (AD-02).

---

### AD-18: Inventories hold control-plane hosts only

**Decision.** `inventories/{dev,nonprod,prod}/` contain **only** control-plane / landing-zone
hosts that are stable and long-lived (AAP nodes, runners, jump hosts, bastion). Ephemeral
build targets are **not** in them.

Target selection for a run comes from one of two places:

| Use case | Source |
|---|---|
| The run's own servers | `inventory.json` generated from `context.json` by `scripts/generate_inventory.py` — **exact**, no API race, no accidental extra hosts |
| Operational / ad-hoc / drift | Native provider inventory plugins (`azure_rm`, `aws_ec2`, `gcp_compute`) filtered by tags |

**Why — this resolves a §4 vs §10 conflict.** §4's tree shows
`inventories/{dev,nonprod,prod}/hosts.yml` with `group_vars/{all,azure,aws,gcp,linux,windows}`.
§10 says "Do not maintain large static inventories of ephemeral cloud servers."

If a run provisions `count: 2` for `PAYMENTS/PROD` and the target is selected by tag filter
over the whole subscription, a **third** machine with stale tags gets configured. That is a
real and serious failure mode. The platform must target **exactly** what it just provisioned,
which is what `sba_instance_id` (AD-05) makes possible: the tag filter is
`SbaInstanceId in [ids from context.json]` — an exact set, not a fuzzy selector.

`group_vars/{azure,aws,gcp,linux,windows}` are retained in the *control-plane* inventories for
defining **vault variables, EE/credential references and per-environment defaults** — which is
what those directories are genuinely useful for — not for defining ephemeral hosts.

**Consequence.** Provider inventory plugins are still used, but only where a fuzzy query is the
actual intent (`server_validate`, drift detection, cost reporting), never for build targeting.

---

### AD-19: Derived fields are resolved server-side by ServiceNow

**Decision.** The run contract contains 9 fields. Six are user- or catalog-supplied; three are
resolved by **ServiceNow itself** before the contract is built.

```json
{
  "schema_version": "1.0.0",
  "request_id": "RITM0012345",
  "application": "PAYMENTS",
  "environment": "PROD",
  "cloud": "AZURE",
  "region": "AMS",
  "server_role": "APPLICATION",
  "os": "WINDOWS",
  "count": 2
}
```

| Field | Source | User-editable? |
|---|---|---|
| `application` | catalog variable (choice from app register) | yes, choice only |
| `environment` | catalog variable (choice from env register) | yes, choice only |
| `cloud`, `region` | derived from the application's approved cloud footprint in the ServiceNow app register | **no** — informational, and validated against the catalog |
| `server_role` | catalog variable (choice) | yes, choice only |
| `os` | catalog variable (choice) | yes, choice only |
| `count` | catalog variable, Dynamic Quantity, `1..N` by role | yes, bounded |
| `request_id` | `sys_id`/number of the RITM | **no** |
| `requested_by` | `opened_by` of the RITM | **no** — *excluded from the contract, see below* |
| `change_reference` | looked up from the RITM's linked CHG | **no** |

**Why `requested_by` is dropped from the wire contract.** §6's example includes it, but it is
(a) trivially derivable by ServiceNow, (b) a **PII/identity field** that would then propagate
into cloud tags, the run-state store and the build log, multiplying the places PII must be
protected, and (c) spoofable if it comes from a client. The platform does not need it as an
input: correlation uses `request_id` + `correlation_id` + `run_id`. If a human-readable actor
is needed for audit, it is read back from ServiceNow on demand.

**Consequence.** The contract is minimal and non-spoofable, which is what makes it safe to
accept from an AI agent (§29). The ServiceNow-side field mapping is in
[api-contract.md](../api/api-contract.md#5-servicenow-field-mapping).

---

### AD-20: Additive schema versioning only

**Decision.** Every contract carries `schema_version` (semver). Changes are **additive only**
within a major version: new fields with defaults, new enum members only at minor bumps with
resolver tolerance for unknown members, never a removed or retyped field.

Consumers must **ignore unknown fields** and must **reject unknown major versions**.

**Why.** §29 commits to accepting requests from a future chatbot/AI agent, and §28 from
"future API consumers". A chat platform's release cadence is not ours. A narrow, additive
contract means a future consumer can be built against this schema without a platform release —
and, more importantly, without the platform having to accept arbitrary structure.

Corollary: the resolver validates enum membership against a **closed** set and fails with
`UNSUPPORTED_ENUM_VALUE` (a clear, actionable error for the requester) rather than
passthrough. Never "accept anything and let the cloud reject it".

---

### AD-21: Single active engine per run

**Decision.** A run is executed by exactly one engine for its entire lifetime. Engine
handoff mid-run is prohibited.

**Why.** Engine handoff would require the two engines to share a run-state backend, agree on
locking semantics, agree on inventory generation, and agree on result schema — at which point
you have built the Automation Gateway (AD-10) and two schedulers, in order to avoid building
the Automation Gateway.

**Exceptions (all within one engine).**
- AAP Workflow → AAP Job Template is intra-engine and fully supported (it is the natural
  expression of §13).
- GitHub Actions reusable workflow → composite action is intra-engine and supported.

**Consequence.** Cross-engine failover is a **runbook action**, not automation: if the AAP
controller is down, an operator follows the "manual engine failover" runbook to re-dispatch
the *remaining* stages to GitHub Actions, using the same `context.json`. This works precisely
because the run state is external to both engines (AD-04). It is documented, manual, and
audited — which is the correct level of automation for a path that should essentially never be
taken.

---

### AD-22: Resolver is read-only and side-effect free

**Decision.** The configuration resolver performs no network calls, no writes and no clock
reads (except via an explicit `as_of` parameter). It is a pure function:

```
resolve(request, catalog, as_of) -> (resolved_configuration, provenance, diagnostics)
```

All existence, quota, capacity and policy checks that require a live API are performed in a
**separate pre-flight stage** (`stage: validate`) using read-only cloud credentials.

**Why.** Three reasons.
1. *Testability* — §26 requires unit tests. A pure function is exhaustively testable; a
   networked resolver is not.
2. *Security* — the resolver runs first, before any cloud identity is acquired. Keeping it
   free of cloud calls means the lowest-privilege component in the platform never handles a
   cloud token.
3. *Determinism* — the same request must resolve to the same configuration for audit
   purposes. A resolver that silently reads "the newest approved image" at resolve time
   produces runs that are not reproducible from the contract.

**Consequence.** Image *expiry* is resolved against `as_of` and the pinned image is stored in
`context.json` (AD-07); quota checks are in `validate`; both are visible in the run report
with their own timestamps.

---

## 2. Requirement Conflict Register

Conflicts between requirements in `PROJECT_BOOTSTRAP.md`, or between a requirement and a hard
platform limit. Severity: **Blocker** (cannot ship without resolution) · **High** ·
**Medium**.

| ID | Conflict | Sources | Resolution | Sev |
|---|---|---|---|---|
| [C-01](#2-requirement-conflict-register) | Naming pattern produces 19-char names; Windows AD computer name limit is 15 | §23 vs Stage 4 / §21 | [AD-06](#ad-06-two-name-model-short-netbios-name--long-fqdn): two-name model; long name preserved for FQDN, short name derived and policy-gated | **Blocker** |
| [C-02](#2-requirement-conflict-register) | 12 mandatory tags; GCP label values ≤63 chars, keys must be lowercase, labels immutable while running | §24 vs GCP limits | [AD-11](#ad-11-gcp-labels-for-indexable-subset-annotations-for-full-metadata): label/annotation split with a per-provider `TagMapper` | **Blocker** |
| [C-03](#2-requirement-conflict-register) | Workflows in `automation/github/workflows/`; GitHub only runs workflows in `.github/workflows/` | §4 vs §11 | [AD-12](#ad-12-canonical-workflows-live-in-githubworkflows) | **Blocker** |
| [C-04](#2-requirement-conflict-register) | Root `galaxy.yml` makes the repo a Collection; §4 tree is a Project layout | §4 internal | [AD-13](#ad-13-this-repo-is-an-ansible-project-not-a-collection): no `galaxy.yml`; AAP Project with Git SCM | High |
| [C-05](#2-requirement-conflict-register) | "Each stage independently executable" vs "do not create one giant playbook" vs "no duplicate logic between GitHub and AAP" | §5 vs §31 vs §12 | [AD-01](#ad-01-single-entry-playbooks--staged-re-entry): one entry playbook, stage-parameterised re-entry | High |
| [C-06](#2-requirement-conflict-register) | §3 shows an Automation Gateway service; §11/§12 show direct calls; §28 wants a general HTTP API | §3 vs §11/§12 vs §28 | [AD-10](architectural-decisions.md#ad-10-no-automation-gateway-service-in-v1): contract now, service deferred with explicit revisit triggers | High |
| [C-07](#2-requirement-conflict-register) | Static per-environment inventories vs "no large static inventories of ephemeral servers" | §4 vs §10 | [AD-18](#ad-18-inventories-hold-control-plane-hosts-only): control-plane only; run targets generated from `sba_instance_id` set | High |
| [C-08](#2-requirement-conflict-register) | `include_role` with a Jinja-interpolated role name is a runtime code-loading primitive | §9 example | [AD-08](#ad-08-provider-abstraction-via-a-fixed-contract--role-allow-list): closed enum + static import list | High |
| [C-09](#2-requirement-conflict-register) | `requested_by` / `change_reference` as user-supplied contract fields | §6 vs §14 (SN derives them) | [AD-19](#ad-19-derived-fields-are-resolved-server-side-by-servicenow): SN resolves them; `requested_by` removed from the wire contract (PII) | Medium |
| [C-10](#2-requirement-conflict-register) | Extra-vars and workflow inputs are logged in cleartext; §15 forbids logging secrets | §12/§15 vs engine behaviour | [AD-15](#ad-15-no-secrets-in-extra_vars--workflow-inputs): credentials only via credential stores; vault unused in git | High |
| [C-11](#2-requirement-conflict-register) | §4 lists `schemas/` in Phase 1 but "Request schema" in Phase 2 | §30 Phase 1 vs Phase 2 | Schemas authored in Phase 1 as **contracts** (they are spec artefacts, reviewable as docs); **validation code** in Phase 2 | Low |
| [C-12](#2-requirement-conflict-register) | `cloud/azure_vm` role names violate the `role-name[path]` ansible-lint rule | §4 vs §17 | `role-name` schema widened to allow a single subdirectory level; documented in `.ansible-lint.yml` rather than skipped | Low |
| [C-13](#2-requirement-conflict-register) | §9's dynamic include is a single name for both VM and image resources | §9 | Split into two closed enums: `sba_cloud_role` and `sba_image_role` (see [AD-08](#ad-08-provider-abstraction-via-a-fixed-contract--role-allow-list)) | Medium |
| [C-14](#2-requirement-conflict-register) | Root `collections/` is not a standard Ansible project collection path | §4 | `collections/ansible_collections/<ns>/<name>` for locally vendored shims only, wired via `collections_path`; all real dependencies live in the EE | Low |
| [C-15](#2-requirement-conflict-register) | `count > 1` plus parallel builds risks quota exhaustion and correlated failure | §6 vs §17 (batching) | `serial` per stage + an environment concurrency semaphore in the run-state store | Medium |
| [C-16](#2-requirement-conflict-register) | AAP "surveys only where absolutely necessary" vs needing stage parameters on dispatch | §12 | Surveys are not used for technical parameters. A single opaque `run_context_id` is passed; AAP reads the contract from the run-state store. Surveys reserved for operator-initiated manual runs only | Medium |
| [C-17](#2-requirement-conflict-register) | §21 lists `APPROVAL_FAILED` as a platform status, but §1 makes ServiceNow the approver | §21 vs §1/§25 | [AD-17](#ad-17-approval-authority-stays-in-servicenow): platform returns `POLICY_VIOLATION` for technical policy; `APPROVAL_FAILED` reserved for the optional production approval re-verification | Low |
| [C-18](#2-requirement-conflict-register) | §16 lists `terraform fmt/validate` and IaC scanning, but §31 forbids building images and the project is Ansible-only | §16 vs §31 | `terraform` tools are **conditional** on the platform's own landing-zone repo, not this one. `checkov`/`trivy` apply to generated IaC artefacts if the enterprise image pipeline emits them. Documented scope exclusion | Low |

---

## 3. Cross-Cutting Invariants

These hold everywhere. They are the acceptance criteria for any new role, stage or engine
adapter, and each is mechanically checkable (Phase 9 adds the automated enforcement).

| # | Invariant | Enforcement |
|---|---|---|
| I-1 | No infrastructure value is ever supplied by a requester. | Contract schema has `additionalProperties: false` (§9 fields rejected) |
| I-2 | No secret is ever an input, an extra-var or a workflow input. | Secret scanning + custom lint rule; [AD-15](#ad-15-no-secrets-in-extra_vars--workflow-inputs) |
| I-3 | Every cloud mutation is tagged with all §24 metadata before it is committed. | Role contract requires `sba_tags`; `policy_gate` asserts tag completeness pre-flight |
| I-4 | Every provisioned instance carries `sba_instance_id`, and it is never regenerated for a logical server. | Contract test in provider roles |
| I-5 | Every stage is idempotent and re-runnable alone. | Stage re-entry test in Molecule + integration suite |
| I-6 | Every stage writes a `result.<stage>.json` before exit and exits non-zero on non-`SUCCESS`. | Stage wrapper role (not optional) |
| I-7 | Every log line is attributable to `request_id` + `run_id` + `sba_instance_id` (where applicable). | Structured callback config; log assertions in integration tests |
| I-8 | No role contains a hard-coded subscription/VPC/subnet/image/OU ID. | `gitleaks`/`semgrep` custom rules; grep gate in CI |
| I-9 | All Ansible module names are fully qualified. | `ansible-lint` `fqcn` rule, blocking |
| I-10 | Dependencies are version-pinned; `latest` is rejected. | `ansible-lint` + custom CI check over `requirements.*`, `execution-environment.yml`, workflows |
| I-11 | The resolver is pure. | Unit tests assert no socket is opened (see [AD-22](#ad-22-resolver-is-read-only-and-side-effect-free)) |
| I-12 | A run's code version is recorded and answerable forever. | `git_sha` + `ee_digest` in `context.json` and the ServiceNow work note |

---

## 4. What Is Explicitly Out of Scope

| Item | Reason |
|---|---|
| OS image *building* | §8, §31. This project consumes approved images only. |
| IaC for landing zones (VPC, VNets, subscriptions, projects) | §31 hard-codes nothing; landing zones are enterprise-managed elsewhere. This project consumes them. |
| Autoscaling / load balancer construction | Stage 8+ application onboarding; out of the build scope. LB *registration* of an existing LB is a DNS/CMDB concern. |
| In-guest application installation | Not a server *build* concern. |
| Kubernetes / container platforms | Different lifecycle, different image model. Explicitly excluded. |
| A stateful Automation Gateway service | [AD-10](architectural-decisions.md#ad-10-no-automation-gateway-service-in-v1). |
| Chatbot / AI agent implementation | §29 forward-compatibility only. The contract is the deliverable. |
| Terraform (own repo) | [C-18](#2-requirement-conflict-register). CI tools listed conditionally. |
| A real ServiceNow instance, cloud subscriptions or credentials | Phase 1 constraint. All design is parameterised; nothing is provisioned. |

---

## 5. Related Documents

| Document | Covers |
|---|---|
| [enterprise-architecture.md](enterprise-architecture.md) | System context, deployment, cross-cutting views |
| [logical-architecture.md](logical-architecture.md) | Layered component model and responsibility matrix |
| [repository-structure.md](repository-structure.md) | Proposed tree, deviations from §4, naming conventions |
| [request-lifecycle.md](request-lifecycle.md) | End-to-end state machine, status model, failure branches |
| [servicenow-github-actions.md](servicenow-github-actions.md) | ServiceNow → GHA flow, dispatch, OIDC, environments |
| [servicenow-aap.md](servicenow-aap.md) | ServiceNow → AAP flow, projects, job/workflow templates, credentials |
| [configuration-resolution.md](configuration-resolution.md) | Resolution hierarchy, merge semantics, conflicts, naming engine, images |
| [provider-abstraction.md](provider-abstraction.md) | Cloud-neutral interface, `TagMapper`, provider dispatch |
| [role-dependency-model.md](role-dependency-model.md) | Role taxonomy, dependency DAG, role contract, ordering |
| [execution-environment.md](execution-environment.md) | EE design, pinning, build/promotion, self-hosted runner hardening |
| [cicd-pipeline.md](cicd-pipeline.md) | Pipeline stages, branch model, promotion, gates |
| [failure-and-retry.md](failure-and-retry.md) | Error taxonomy, error codes, retry classification, compensation |
| [idempotency.md](idempotency.md) | Request/host/stage idempotency, fingerprinting, locking, recovery |
| [security-architecture.md](../security/security-architecture.md) | Trust boundaries, identities, RBAC, logging, supply chain |
| [secret-management.md](../security/secret-management.md) | Per-engine secret patterns, rotation, OIDC, Vault policy |
| [api-contract.md](../api/api-contract.md) | HTTP contract, ServiceNow field mapping, versioning |
| [testing-strategy.md](../testing/testing-strategy.md) | Test pyramid, tooling, gating, coverage targets |
| [../roadmap.md](../roadmap.md) | Phased delivery plan with entry/exit criteria |
| [../assumptions.md](../assumptions.md) | Assumptions and their falsification impact |
| [../open-questions.md](../open-questions.md) | Questions requiring a platform-owner decision |
