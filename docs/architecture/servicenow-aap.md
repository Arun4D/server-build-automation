# ServiceNow → Ansible Automation Platform (AAP) Integration

Status: **Phase 1 — Proposed**

Design for the AAP execution path: the API surface, Projects, Job and Workflow Templates,
credentials, Execution Environments, RBAC, approval nodes, and how AAP stays a scheduler
rather than a second implementation of the automation.

Decisions: [AD-09](architectural-decisions.md#ad-09-per-environment-engine-routing) (prod
default), [AD-13](architectural-decisions.md#ad-13-this-repo-is-an-ansible-project-not-a-collection) (this repo is an
Ansible **Project**, not a Collection), [AD-01](architectural-decisions.md#ad-01-single-entry-playbooks--staged-re-entry)
(no duplicated orchestration), [AD-15](architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs)
(credentials only in the credential store).

---

## 1. Role of This Path

Per [AD-09](architectural-decisions.md#ad-09-per-environment-engine-routing), AAP is the
**default engine for `prod`**, and the escalation path for anything requiring strong audit,
credential isolation, approval gates or long-running execution.

Why AAP for production, stated concretely rather than generically:

| Capability | Why it matters for production builds |
|---|---|
| **External credential store** | Credentials are referenced by name in job templates. A user who can launch a job cannot read the credential. This is the property §12 relies on ("Automation Controller is designed to allow teams/users to use credentials without exposing the underlying secret values") and it is the single strongest reason to prefer AAP here |
| **Execution Environments** | Pinned, immutable, digest-referenced toolchain ([execution-environment.md](execution-environment.md)); a prod build cannot be affected by a collection upgrade |
| **RBAC + Teams + Object Roles** | The platform operator can launch a prod build without being an operator; a requester can never launch one |
| **Workflow approval nodes** | A human approval step *inside* the execution, not only before dispatch |
| **Instance groups / job slicing / capacity** | Predictable prod capacity; nonprod cannot starve prod |
| **Audit retention** | Job history retained on AAP's own terms, independent of CI log retention |
| **Consolidated controller logging** | Event forwarding to the SIEM from one system rather than per-provider |

What AAP does **not** give that GitHub Actions does, and why it does not matter: PR-native CI
integration. That is why runtime production builds and repository CI are separate concerns
([cicd-pipeline.md](cicd-pipeline.md)).

---

## 2. End-to-End Flow

```
  ServiceNow              AAP Controller API          AAP instance             Platform
      |                        |                          |                      |
 (1)  | build contract         |                          |                      |
      |------------------------>|                          |                      |
 (2)  |                        | OAuth2 / token           |                      |
      |                        | (machine-to-machine)     |                      |
      |                        |                          |                      |
 (3)  |                        |--GET /api/controller/    |                      |
      |                        |   projects/?name=X       |                      |
      |                        |<--project id-------------|                      |
      |                        |                          |                      |
 (4)  |                        |--POST /api/controller/   |                      |
      |                        |   job_templates/<id>/    |                      |
      |                        |   launch/                |                      |
      |                        |  {extra_vars:            |                      |
      |                        |     {run_context_id},    |                      |
      |                        |     limit: "dev,nonprod,prod",|
      |                        |     job_tags: {...}}     |                      |
      |                        |                          |                      |
 (5)  |                        |<--201 {id, url, status}--|                     |
      |<-202 {run_id, url}-----|                          |                      |
      |                        |                          |  Project sync -> git |
      |                        |                          |  EE pulled by digest|
      |                        |                          |  resolve -> validate  |
      |                        |                          |  -> stages 1..8      |
      |                        |                          |                      |
 (6)  |                        |--GET /unified_jobs/<id>/ |                      |
      |<--poll with backoff----|  {status, finished,      |                      |
      |                        |   elapsed}               |                      |
      |                        |                          |                      |
 (7)  |  callback (P2) from the adapter, never from inside the job:              |
      |<-------------------------------------------------------------------------|
      |  RITM update, work note, audit                                          |
      v
```

**Step 7 again:** the callback comes from the adapter, not the job. A job step has no
ServiceNow identity, and giving it one would put a ServiceNow secret in the AAP Credential
store bound to *every* job in the template — including the ones an operator launches by hand.
The job writes results; the adapter moves them. This is the same division as the GitHub path
([servicenow-github-actions.md §2 ](servicenow-github-actions.md#2-end-to-end-flow)), which is
what makes the two paths interchangeable ([AD-21](architectural-decisions.md#ad-21-single-active-engine-per-run)).

---

## 3. The Launch Call

The only API call that creates work. Everything else is read-only.

```
POST {aap_base_url}/api/controller/job_templates/{job_template_id}/launch/
Authorization: Bearer <token from OAuth2 client-credentials, scope: write:job_template>
Content-Type: application/json

{
  "extra_vars": {
    "run_context_id": "01HQ8Z...RITM0012345"
  },
  "job_tags": [
    "sba:request_id=RITM0012345",
    "sba:environment=prod",
    "sba:correlation_id=0192f3a4-...",
    "sba:app=payments",
    "sba:stage=all"
  ],
  "limit": "dev,nonprod,prod"
}
```

Response `201`:

```json
{
  "id": 4821,
  "url": "https://aap.corp.example.com/api/controller/job_templates/12/jobs/4821/",
  "status": "pending"
}
```

### 3.1 Why only `run_context_id` is passed

[C-16](architectural-decisions.md#2-requirement-conflict-register) — the single most important decision in this
document. The alternative designs and why each is rejected:

| Alternative | Why rejected |
|---|---|
| Survey fields for `vm_size`, `subnet`, `image`, `region`, `os` | Re-exposes every technical parameter at the engine boundary — exactly what §2 of the bootstrap forbids. Also makes a survey edit a production change, and surveys are not version-controlled with the code |
| `extra_vars` carrying the full resolved configuration | The values would be **visible in the AAP job detail page and the audit log** to anyone with read access to the job ([AD-15](architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs)). Even without secrets, it distributes estate topology to a wider audience than the run-state store, and it makes the job non-reproducible from its own record |
| Re-running resolution inside the job | Two resolvers (adapter-side and job-side) that can disagree. Resolution happens once, in the platform, and its output is durable |
| Passing the whole `context.json` as a huge extra-var | Same visibility problem, at 50× the size |

So: the job receives an **opaque pointer** and reads the authoritative context from the
run-state store using the job's cloud identity. The job detail page shows a `run_context_id`
and a `git_sha` — which is all an operator needs to diagnose, and nothing an operator should
not see.

**What the job detail page legitimately shows**, and why each is safe:

| Field | Value | Safe because |
|---|---|---|
| `run_context_id` | Opaque ULID | Points at the store, grants no access |
| `sba_git_sha` | 40-char SHA | Identifies code; no topology |
| `sba_correlation_id` | UUID | Correlation only |
| Job tags | `request_id`, `environment` | Business identifiers, non-sensitive |
| Job log | Redacted | `no_log` on every credential-consuming task |

### 3.2 `limit` and `job_tags`

`limit` restricts which AAP **instances** may run the job. Setting it explicitly, rather than
inheriting a default, means a job template cannot be launched onto an instance that lacks the
prod identity — a control that survives someone creating an instance without thinking.

`job_tags` give searchability and per-request capacity accounting. They are metadata only, and
deliberately exclude resolved technical values for the same visibility reason as `extra_vars`.

---

## 4. Projects

| Property | Value | Why |
|---|---|---|
| `scm_type` | `git` | Content lives in GitHub ([AD-13](architectural-decisions.md#ad-13-this-repo-is-an-ansible-project-not-a-collection)) |
| `scm_url` | `https://github.com/ORG/server-build-automation.git` | Single source of truth shared with the GitHub path |
| `scm_branch` | `main` (dev), `release/*` (nonprod), pinned tag (prod) | Branch-to-environment mapping ([cicd-pipeline.md §3 ](cicd-pipeline.md#3-branch-and-promotion-model)) |
| `scm_ref` | — | Left empty deliberately. `scm_ref` is a branch name; using a tag/branch here would make production follow a moving ref |
| `scm_update_on_launch` | `false` (dev/nonprod), `true` (prod) | `false` gives a deterministic commit; `true` means the latest commit on the pinned branch at launch |
| `scm_update_cache_timeout` | `300` (dev), `3600` (prod) | Balances freshness against API rate limits |
| Credential | `SCM` type, GitHub deploy key or token, **in the credential store only** | Never in git |
| `default_environment` | per-environment EE (dev / nonprod / prod), by digest | The EE is the versioned toolchain |

**Two different pins, two different jobs.** `scm_branch` (AAP) selects the branch the project
syncs; the pinned commit for the *run* comes from `config_ref` in the run-state store
(`[AD-20](architectural-decisions.md#ad-20-additive-schema-versioning-only)`, I-12). The
adapter records the resolved commit in `context.json`, so a build is always attributable to a
commit even if the branch has moved on. This is the AAP equivalent of the GitHub pinned `ref`
([servicenow-github-actions.md §3.2 ](servicenow-github-actions.md#32-the-hard-github-constraint)).

**A commit not on the configured branch is refused by AAP itself.** This is a useful property:
it means the prod project cannot be made to run arbitrary code by pointing it at a branch,
because the project definition is under change control in AAP while the branch is under change
control in GitHub — two independent controls on the same resource.

---

## 5. Workflow Template Design

§13 specifies a START → … → POST BUILD (fan-out) → SUCCESS sequence. In AAP this maps to a
**Workflow Template**, which is *intra-engine* orchestration and therefore fully compatible
with [AD-01](architectural-decisions.md#ad-01-single-entry-playbooks--staged-re-entry): the
workflow template sequences **invocations of one playbook**, and contains no Ansible logic.

```
  [Job Template: SBA / Validate]        resolve + pre-flight        exit 0 = pass
        |
        v
  [Workflow Node: Failure Handler]      only reached on != 0
        |
  [Job Template: SBA / Build]           server_build.yml -e stage=all
        |
        v
  [Job Template: SBA / Report]          reporter -> run_result.json
        |
        v
  [Job Template: SBA / Callback]        no-op in AAP; the adapter does this
        |
        v
  [Job Template: SBA / Post-Build]      stages 4-7, re-runnable alone
        |
        v
  SUCCESS
```

Node semantics, and the decisions they encode:

| Node type | Node | Purpose |
|---|---|---|
| **Job template** | `SBA / Validate` | Pre-flight. Failure → Failure Handler, no infrastructure touched |
| **Job template** | `SBA / Build` | `ansible-playbook playbooks/server_build.yml -e @context.json` |
| **Workflow** (nested) | `Failure Handler` | Writes a failure result, sets the terminal status, leaves infrastructure per [AD-16](architectural-decisions.md#ad-16-forward-fix-over-auto-destroy) |
| **Workflow** (nested) | `Post-Build Fan-out` | Sequences domain → agents → dns → cmdb, with a `PARTIAL` branch so a failure in one does not skip CMDB registration for healthy hosts ([request-lifecycle.md §5.2 ](request-lifecycle.md#52-failure-of-post-build-stages-after-partial-success-within-a-stage)) |
| **Approval** | `Prod Approval` (prod workflow only) | Human gate **inside** execution, per §13 and the AAP model |
| **Job template** | `SBA / Callback` | Present for symmetry with the GHA path; the adapter performs the callback |
| **Workflow** | `Failure Handler` | Terminal |

### 5.1 Why a workflow template and not one job template

A single job template would be simpler, and the stage machine would still work. The reasons for
the workflow template:

1. **§13 explicitly asks for an AAP workflow** with clear success/failure outputs per stage.
2. **The Failure Handler is a first-class node.** Having failure routing as a node rather than
   as playbook `block`/`rescue` means failure handling is visible in the AAP UI to an operator
   mid-incident, and it is under change control as an AAP object.
3. **The prod approval node** is an AAP feature; a job template cannot express it.
4. **Post-build fan-out** is exactly the shape a workflow node expresses, and §5 requires those
   stages to be independently executable — which they are, because each node invokes the same
   playbook with a different `stage`.

### 5.2 Node parameters — what a node may contain

| Allowed in a node | Forbidden in a node |
|---|---|
| Job template reference | Any Ansible task, module, or `ansible.builtin.*` name |
| `stage` variable (a stage **name** from the fixed list) | Any resolved technical value |
| `run_context_id` | Any credential, token, or secret |
| `limit`, `job_tags`, `timeout` | A `shell`/`command` task that does something a playbook should do |
| Node failure/success routing | Conditional logic that would differ from the playbook's own guards |

**The review question for any change to a node:** *"does this make the GitHub path behave
differently?"* If yes, it is the wrong place. A node that grew a `when: cloud == 'azure'`
branch would be the first step toward the duplication §31 forbids, and it would be invisible in
a diff against `server_build.yml`.

### 5.3 Stage list — one definition

The stage names are a fixed enumeration shared by `server_build.yml`, the workflow template,
the GitHub workflow `stage` input, the AAP adapter and the run-state store:

```
  all | validate | provision | os_config | validate_os
    | domain_join | install_agents | dns | cmdb
    | report | destroy
```

`server_build.yml` owns the mapping from a stage name to roles. The other four are consumers of
the enumeration. If a stage is added, `server_build.yml` plus a documentation update is
sufficient; the engines pick it up from the playbook, and an unknown name fails with a clear
error rather than a skipped stage.

---

## 6. Execution Environments

Per [execution-environment.md](execution-environment.md). The AAP-specific requirements:

| Aspect | Decision | Why |
|---|---|---|
| **EE selection** | Per-environment EE, referenced **by digest** | A mutable tag would let a collection update change a production build's toolchain — the dependency-floating problem §18 forbids |
| **Job template** | `execution_environment: <prod-ee-digest>` explicitly, not inherited | Explicit is auditable; inherited hides what actually ran |
| **EE pull policy** | `always` (re-check the registry) | A digest is immutable, so re-checking is cheap and detects a registry inconsistency |
| **Registry** | GHCR or a private Quay, network-reachable from AAP | Same registry as the GitHub path |
| **Isolation** | Separate AAP clusters (or at minimum separate instance groups + credential stores) per environment | A credential-store boundary is a real security boundary; a shared store means a dev user can reference a prod credential by name |
| **`ansible.cfg`** | Mounted from the project; `collections_path` and interpreter discovery are the only overrides | One config for both engines ([AD-13](architectural-decisions.md#ad-13-this-repo-is-an-ansible-project-not-a-collection)) |

**`collections_path` note.** The project must not rely on collections being present in the EE
*and* in a local `collections/` directory with different versions — the classic "works on the
controller, fails in the EE" defect. The project declares a pinned set, the EE builds from that
same pinned set, and CI asserts the two agree ([execution-environment.md §4 ](execution-environment.md#4-version-consistency-verification)).

---

## 7. Credentials

AAP's credential store is the **only** long-lived secret home on this path
([secret-management.md](../security/secret-management.md#4-ansible-automation-platform)).

| Credential | Type | Used by | Notes |
|---|---|---|---|
| `sba-scm-github` | SCM (git) | Project sync | Deploy key or scoped token; read-only on this repo |
| `sba-cloud-azure-{env}` | Cloud / OpenID Connect | `azure_vm`, `azure_image` | Or OIDC-backed, no stored secret at all |
| `sba-cloud-aws-{env}` | Amazon Web Services | `aws_ec2`, `aws_image` | OIDC where the AAP instance has a role |
| `sba-cloud-gcp-{env}` | Google Compute Engine | `gcp_compute`, `gcp_image` | Workload identity where available |
| `sba-state-store-{env}` | Storage / secret | `run_state` | Ideally identity-based, no key |
| `sba-servicenow-cmdb` | HTTP Basic / OAuth2 client | `servicenow_cmdb` | Scoped integration account; write to CI only |
| `sba-domainjoin` | username/password | `windows_domain_join`, `linux_domain_join` | Dedicated non-interactively-logonable account; `no_log: true` on every consuming task |
| `sba-servicenow-approval` | OAuth2 client | `validate` (optional prod check) | Read-only |
| `sba-monitor-{env}` | HTTP header / token | `monitoring_agent` | Enrollment token |
| `sba-backup-{env}` | token | `backup_agent` | Enrollment token |
| `sba-vulnscanner` | token | `vulnerability_agent` | Enrollment token |
| `sba-dns-{env}` | token / key | `dns_registration` | Zone-scoped |
| `sba-runner-bootstrap` | one-time | runner/EE setup | Short-lived; not attached to any job template |

### 7.1 Credential hygiene rules

| Rule | Enforcement |
|---|---|
| A credential is never attached to a job template that a requester can launch | Job template inventory is reviewed; only the `prod` job templates with approval nodes use prod credentials |
| Every consuming task sets `no_log: true` | ansible-lint rule + a CI grep gate; a task using a credential without `no_log` is a lint failure |
| `asked` is only used where genuinely interactive | A prompt in a headless job is a hang; the lint rule flags it |
| No credential is passed in `extra_vars` | [AD-15](architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs) |
| AAP's "prevent update" (`ask_..._on_launch`) is **off** | If on, a launcher can inject their own credential value. This is a real and commonly-missed setting |
| Credential values are never read back by automation | No `GET /credentials/{id}/` usage in our code; the API returns redacted values, and reading them is forbidden by policy |
| Credential names are referenced from a non-secret allow-list | Configuration, not code, and reviewable in git |
| Rotation is by credential *name* | A role rotation replaces the value; no playbook change, no run-state change |

The `ask_*_on_launch` point is worth calling out because it is the mechanism by which AAP's
otherwise-excellent credential isolation is quietly defeated: with it enabled, whoever launches
the job supplies the credential value, so the store is bypassed entirely. It must be
**disabled** on every credential used by a launchable job template, and it is checked in the
AAP configuration review.

---

## 8. RBAC and Access Model

Five roles, mapping to AAP Teams, with Object Roles bounding what each may launch.

| Team / role | May | May not |
|---|---|---|
| **Requester** (does not exist as an AAP team) | — | Everything in AAP. Requesters only interact through ServiceNow |
| **Platform Operator** | Launch any job template; read all jobs; manage inventory/credentials *in their environment only* | Access another environment's credential store; edit the prod workflow template without approval |
| **Platform Approver** | Approve the prod approval node; read all jobs | Launch jobs; edit templates |
| **Platform Viewer** | Read job output, results, host inventory, project sync status | Launch anything; see credential values (never possible) |
| **Automation Service** | The `svc-sba-servicenow` AAP token: launch the dispatch job template only | Anything else; a launch-only token, scoped to one template |

Object Roles ( AAP feature) bound the *what*:

| Object | Permitted roles | Scope |
|---|---|---|
| Job Template `SBA / Build` (prod) | Automation Service, Platform Operator | With the approval node required |
| Job Template `SBA / Build` (dev/nonprod) | Automation Service, Platform Operator | No approval |
| Credential `sba-cloud-*` (prod) | Platform Operator, Automation Service | Never Requester |
| Inventory (prod) | Platform Operator, Platform Viewer | Read/write per object role |
| Project (prod) | Platform Operator | Operated centrally |

**The `svc-sba-servicenow` token is the security boundary for the entire ServiceNow
integration.** It should be able to do exactly one thing: launch the dispatch job template. A
token that can create templates, read credentials or launch arbitrary job templates turns a
ServiceNow compromise into arbitrary infrastructure execution. This token is therefore:

- issued per environment,
- scoped to one job template with a launch-only permission,
- short-lived where AAP supports it, rotated on a schedule and on any ServiceNow admin change,
- and its use is logged in AAP's event stream, which is part of the audit trail.

---

## 9. Approval

Two approval points, at different layers, for different reasons.

```
  ServiceNow approval (Layer 1)          AAP approval node (Layer 2)
  ─────────────────────────────           ─────────────────────────
  Business: is this change authorised?   Technical: is this build allowed
  Who approved it, when, under what       to run *now*, with these
  policy. Recorded in the CHG.           parameters, on this capacity?
  Never re-implemented in the            Required for prod by policy.
  platform [AD-17].                      Native AAP feature; an
                                         operator with no ability to
                                         edit templates approves it.
```

Layer 1 is mandatory for governed environments and is enforced in ServiceNow. Layer 2 is
mandatory for production per the platform's own policy, and is a separate control: it means
that even a correctly-approved change cannot consume production capacity without a platform
operator present, and that the operator sees the actual resolved configuration (from the
run-state store) before releasing it.

A production job that waits at an approval node for 3 days is not a stuck job; it is a
legitimately paused one. The `provision` stage has not started, no infrastructure exists, and
the AAP job timeout must therefore be set above the expected approval dwell time
([request-lifecycle.md §11 ](request-lifecycle.md#11-timeline-and-budgets)). Setting a job
timeout shorter than the approval window converts a pause into a failure.

---

## 10. Status Read-Back and Callback

| Path | Mechanism |
|---|---|
| **Status polling** | `GET /api/controller/unified_jobs/{id}/` → `{status, finished, elapsed, failed, job_url}`. The *unified job* id from the launch response, not the job id — the launch response's `id` is a job id and the URLs differ; the adapter must use the unified job consistently |
| **Callback** | Adapter, on terminal status, POSTs to ServiceNow ([api-contract.md §6 ](../api/api-contract.md#6-callback-contract)) |
| **Reconciliation** | ServiceNow scheduled job, independent of both ([request-lifecycle.md §8 ](request-lifecycle.md#8-status-reconciliation)) |

Status mapping, and the same principle as the GitHub path — **AAP's status is transport
metadata; `run_result.json` is authoritative**:

| AAP unified job status | Platform status |
|---|---|
| `new`, `pending`, `waiting`, `scheduled` | `QUEUED` (or `APPROVED_TO_DISPATCH` if awaiting approval) |
| `running` | `IN_PROGRESS` |
| `successful` | `SUCCESS` — **only if the artifact agrees** |
| `failed`, `error`, `canceled` | `PARTIAL` / `FAILED` / `CANCELLED`, from the artifact |
| `never ran` | `MANUAL_ATTENTION` — a timeout before the node executed. Distinguish this from a job that ran and failed; the remediation differs completely |

`never ran` is a genuinely distinct and easily-mishandled state: it means the job was never
executed (timeout waiting for capacity or an approval), **not** that the automation failed.
Reporting it as `FAILED` would send an operator to debug a playbook that never ran.

Polling backoff is identical to the GitHub path: 30 s, 60 s, 120 s, 300 s, then 300 s, capped
at the stage's p95 budget + 50%.

---

## 11. Idempotency

The adapter holds the same guarantees as the GitHub path, and the AAP API gives it a clean way
to do so.

| Guarantee | Mechanism |
|---|---|
| A repeated identical contract does not launch a second job | `fingerprint.json` check before launch; return the existing `run_id` with `duplicate: true` |
| A retried launch after a partial failure does not double-launch | The launch response `id` is recorded **before** returning success to ServiceNow; a retry finds it |
| A job launched for a contract that already succeeded is refused | `context.json` terminal status checked before launch; returns the completed result |
| A modified contract for an existing `request_id` is refused | `409 REQUEST_MODIFIED` — an approval-integrity issue, for a human ([idempotency.md §7 ](idempotency.md#7-per-stage-idempotency-contract)) |

The AAP `extra_vars.idempotency_token` / launch-level de-duplication is **not** relied upon. It
is job-template-scoped and its retention is a platform setting, whereas the run-state store's
fingerprint is under our control, is auditable, and is the same mechanism on both engines.
Relying on an engine feature for a cross-engine guarantee would break the symmetry the design
depends on.

---

## 12. Failure, Cancellation, Timeout

| Situation | AAP behaviour | Platform action |
|---|---|---|
| Job fails in a stage | Node `on_failure` routes to the Failure Handler | `run_result.json` written; `PARTIAL`/`FAILED`; infrastructure retained ([AD-16](architectural-decisions.md#ad-16-forward-fix-over-auto-destroy)) |
| Job cancelled | `POST /api/controller/jobs/{id}/cancel/` | Artifact written; `CANCELLED`; infrastructure retained |
| Controller restart mid-run | Job may be lost or marked failed | Reconciliation job → `MANUAL_ATTENTION` with the last known stage |
| Instance capacity exhausted | Job stays `pending`/`waiting` | `QUEUED`; surfaced in the work note; a capacity alert fires before the timeout |
| Timeout while awaiting approval | `never ran` | `MANUAL_ATTENTION`, distinctly from a failure |
| Timeout while running | Job `failed` | `FAILED` with `TIMEOUT` and the stage from the artifact |
| `scm_update_on_launch` fails (network/GitHub) | Job fails before running | `SOURCE_UNAVAILABLE`, retryable |
| EE pull fails | Job fails before running | `EE_UNAVAILABLE`, retryable; alert, since it blocks all prod builds |

The last two are worth pre-empting with alerts rather than discovering during an incident: a
broken SCM sync or an unreachable EE registry fails **every** production build instantly and
looks like a mass platform outage. They are availability dependencies of the whole path and
should be monitored as such.

---

## 13. Observability

| Signal | Source | Destination |
|---|---|---|
| Job / unified job status and duration | AAP API | Adapter → run-state store → ServiceNow |
| Structured results | `run_result.json` via `run_state` | Run-state store (authoritative) |
| **Event stream** (job launched, template updated, credential used, user authenticated) | AAP `/api/controller/event_stream/` | SIEM — the authoritative record of *who launched what* |
| Execution log | Controller job log | SIEM, with retention per policy |
| Project sync status | `GET /projects/{id}/` | Alert on repeated failure |
| EE availability | Registry + job launch failures | Alert |
| Capacity | Instance group utilisation, job queue depth | Capacity alerting |
| Credential *usage* count | AAP credential usage stats | Rotation and least-privilege review |

The AAP **event stream** is the security control that matters most here: it records every
template update and every credential use with a user identity. It is how "who changed the prod
job template" is answered, and it is why the platform's own audit story is stronger on AAP than
on GitHub Actions — a contributing reason for the prod routing default
([AD-09](architectural-decisions.md#ad-09-per-environment-engine-routing)).

---

## 14. Testing This Path

| Level | Scope | Notes |
|---|---|---|
| Template inventory test | Every job/workflow template matches the allow-list; no unreferenced template can launch prod credentials | CI, against an AAP test instance |
| Credential hygiene | No `ask_*_on_launch` on any launchable template; every consuming task has `no_log` | CI + AAP config export diff |
| Launch contract test | Mock API; assert `extra_vars` contains only `run_context_id`; `job_tags` carry no technical values; `limit` is explicit | Unit |
| RBAC test | The `svc-sba-servicenow` token can launch exactly one template and nothing else | Integration, in a sandbox AAP |
| Project sync test | Sync from a pinned tag; verify the commit in the job's `scm_revision` matches `context.json` | Integration |
| EE digest test | Job template references a digest; the pulled EE digest matches `context.json.ee_digest` | Integration |
| Approval-node test | A prod job pauses at the approval node, creates no infrastructure, resumes on approval, and exceeds neither timeout | Integration |
| Nonprod E2E | Full ServiceNow → AAP → sandbox cloud → CMDB | Integration, nightly |
| **Cross-engine parity** | Identical stage list on AAP and GitHub ⇒ identical `context.json`, equivalent `run_result.json` | Integration — the mechanical proof of [AD-01](architectural-decisions.md#ad-01-single-entry-playbooks--staged-re-entry) |
| Failure-handler test | Inject a failure at each stage; assert the routing, the artifact, the retained infrastructure, and the reported status | Integration |

The cross-engine parity test is the single most valuable test in the whole project. Everything
else can pass while the two execution paths have silently diverged; that one cannot.

---

## 15. Known Constraints and Accepted Trade-offs

| Constraint | Consequence | Accepted because |
|---|---|---|
| Repo is an Ansible Project, not a Galaxy Collection | Not installable as a collection; consumed as an AAP Project | [AD-13](architectural-decisions.md#ad-13-this-repo-is-an-ansible-project-not-a-collection); matches §4's tree; a later extraction is mechanical |
| Project content is read from Git at launch | A GitHub outage blocks all builds | Mitigated with `scm_update_cache_timeout`; a local checkout mirror is an infrastructure decision, not a design change |
| Approval dwell vs job timeout | Timeout must exceed the approval window | Set explicitly; a pause is not a failure |
| `extra_vars` visibility in job detail | Mitigated by passing only `run_context_id` | [AD-15](architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs); the alternative leaks estate topology |
| AAP is stateful; GitHub Actions is not | Different availability and audit characteristics | Exactly the reason for [AD-09](architectural-decisions.md#ad-09-per-environment-engine-routing)'s split routing |
| Controller capacity is finite | Builds queue in prod | Desirable — it is a control on production change volume |
| No cross-engine handoff | Failover is manual | [AD-21](architectural-decisions.md#ad-21-single-active-engine-per-run); enabled by external run state |

---

## 16. Next

- The GitHub path, for the symmetric design: [servicenow-github-actions.md](servicenow-github-actions.md)
- Engine-neutral contract and callbacks: [api-contract.md](../api/api-contract.md)
- AAP secret patterns: [secret-management.md](../security/secret-management.md)
- EE design and digest pinning: [execution-environment.md](execution-environment.md)
- Project/EE as configuration artefacts: [repository-structure.md](repository-structure.md)
