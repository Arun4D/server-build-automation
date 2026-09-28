# Request Lifecycle

Status: **Phase 1 — Proposed**

End-to-end state machine for a single server build: intake, dispatch, the eight lifecycle
stages, status propagation back to ServiceNow, failure branches, retry, cancellation,
re-entry, reconciliation and garbage collection.

Decision references resolve to [architectural-decisions.md](architectural-decisions.md).

---

## 1. Actors and Responsibilities During a Build

```
  REQUESTER      raises the RITM, sees progress, gets a result. Never sees a technical param.
  APPROVER       approves the change in ServiceNow. Platform does not re-approve.   [AD-17]
  SERVICENOW     owns business state: RITM, approval, work notes, CMDB registration
                 trigger, and the "Manual Attention" branch.
  ADAPTER        owns engine dispatch and status read-back. No business logic.      [AD-02]
  ENGINE         owns the execution slot: queue, runner, EE, job identity.
  PLATFORM       owns the stages, the resolver, the policy gate, the run state.
  CLOUD/AD/DNS   own the actual resource state.
```

Exactly one component is authoritative for each fact, and no two components are authoritative
for the same fact. This is the property that makes the lifecycle debuggable.

---

## 2. Status Model

A single vocabulary shared by the run-state store, both engines' results, and the ServiceNow
update. Additive only, versioned ([AD-20](architectural-decisions.md#ad-20-additive-schema-versioning-only)).

### 2.1 Request status

| Status | Meaning | Terminal | Set by |
|---|---|:--:|---|
| `RECEIVED` | Contract accepted and persisted | no | Adapter |
| `VALIDATING` | Schema + pre-flight in progress | no | Stage machine |
| `VALIDATION_FAILED` | Rejected before any infrastructure was touched | **yes** | Pre-flight |
| `APPROVAL_FAILED` | Production change not in an approved state (optional re-verification only) | **yes** | Pre-flight ([C-17](architectural-decisions.md#2-requirement-conflict-register)) |
| `RESOLVING` | Configuration resolution + naming + image pinning | no | Stage machine |
| `POLICY_BLOCKED` | Configuration resolved but violates an organisational policy | **yes** | Policy gate |
| `APPROVED_TO_DISPATCH` | Pre-flight passed; engine dispatch in progress | no | Adapter |
| `QUEUED` | Accepted by the engine, waiting for a runner | no | Engine |
| `IN_PROGRESS` | A stage is executing | no | Stage machine |
| `STAGE_COMPLETE` | Current stage succeeded, next stage pending | no | Stage machine |
| `PARTIAL` | Some hosts/stages succeeded, some failed. **Infrastructure retained** | **yes** (or resumable) | Stage machine ([AD-16](architectural-decisions.md#ad-16-forward-fix-over-auto-destroy)) |
| `FAILED` | Build failed with no recoverable path by automatic means | **yes** | Stage machine |
| `CANCELLING` | Cancellation requested, in-flight work being stopped safely | no | Adapter |
| `CANCELLED` | Stopped by an authorised human | **yes** | Adapter |
| `SUCCESS` | All stages succeeded; CMDB registered | **yes** | Stage machine |

### 2.2 Stage and host status

| Status | Meaning |
|---|---|
| `PENDING` | Not started |
| `RUNNING` | In progress |
| `SUCCESS` | All tasks in the stage succeeded on this host |
| `SKIPPED` | Deliberately not applicable (e.g. a Windows-only step on Linux) — must be a *decision*, never a silent skip |
| `FAILED` | Failed; `error_code` populated |
| `UNREACHABLE` | Management plane unreachable after retries (transient-class, retryable) |
| `ROLLED_BACK` | Stage's own compensation succeeded |

### 2.3 Status roll-up rules

Per-host results roll up to the stage, stages roll up to the request. These rules are
deterministic and implemented once, in the reporter.

```
  stage status   = SUCCESS   if all hosts in {SUCCESS, SKIPPED} and >=1 SUCCESS
                 = PARTIAL   if >=1 SUCCESS and >=1 FAILED
                 = FAILED    if all hosts FAILED
                 = SKIPPED   if all hosts SKIPPED

  request status = SUCCESS   if all stages SUCCESS
                 = PARTIAL   if some stages SUCCESS and some FAILED/PARTIAL
                 = FAILED    if no stage after the first successful one succeeded
                             AND on_failure policy does not permit retention
                 = PARTIAL   if same, but on_failure policy is retain   [AD-16]

  IMPORTANT: PARTIAL is a normal, expected outcome of a batch build, not an edge case.
  A count:2 request where host 1 joined the domain and host 2 did not is PARTIAL,
  and the correct ServiceNow outcome is "Manual Attention" — never "Failed" with
  no indication that a server exists, and never a silent success.
```

**A stage is never marked `SUCCESS` if a host inside it was skipped without an explicit
policy decision.** Silent skips are how partially-configured servers reach production.

---

## 3. The Lifecycle

### 3.1 Overview

```
  ServiceNow            Adapter         Engine/AAP/GHA        Platform        Cloud/AD/DNS/CMDB
      |                    |                  |                  |                    |
 (1)  | RITM raised        |                  |                  |                    |
      v                    |                  |                  |                    |
 (2)  | Build contract     |                  |                  |                    |
      |  (9 fields)        |                  |                  |                    |
      |------------------->|                  |                  |                    |
 (3)  |                    |--validate------->|                  |                    |
      |                    |--persist request+fingerprint------->  |                    |
 (4)  |                    |                  |                  |                    |
      |                    |<-202 {run_id,url}-|                  |                    |
      |<-------------------|                  |                  |                    |
 (5)  |                    |                  |  S0 RECEIVED     |                    |
      |                    |                  |  S1 RESOLVING    |                    |
      |                    |                  |   resolver       |                    |
      |                    |                  |   naming         |                    |
      |                    |                  |   image pin      |                    |
      |                    |                  |  S2 VALIDATING   |                    |
      |                    |                  |   pre-flight     |---read-only------->|
      |                    |                  |  S3 PROVISIONING |                    |
      |                    |                  |   Stage 1        |---create----------->|
      |                    |                  |  S4 OS_CONFIG    |                    |
      |                    |                  |   Stage 2/3      |---WinRM/SSH-------->|
      |                    |                  |  S5 POST_BUILD   |                    |
      |                    |                  |   Stages 4-7     |---AD/DNS/CMDB------>|
      |                    |                  |  S6 REPORTING    |                    |
      |                    |                  |                  |                    |
 (6)  |                    |                  |  S7 COMPLETE     |                    |
      |<-callback (P2)-----|------------------|----------------->|                    |
      |  or poll (P1)       |                  |                  |                    |
 (7)  |  RITM updated, work note, CMDB, audit |                  |                    |
      v                    |                  |                  |                    |
```

### 3.2 Phases in detail

#### Phase 1 — ServiceNow intake (§1, §14, [AD-19](architectural-decisions.md#ad-19-derived-fields-are-resolved-server-side-by-servicenow))

The catalog exposes 5 user-facing variables and derives 4. No technical value is ever
user-editable.

| # | Contract field | Source in ServiceNow | User-editable |
|---|---|---|---|
| 1 | `request_id` | The RITM's own number | no |
| 2 | `application` | Catalog choice from the app register | yes (choice) |
| 3 | `environment` | Catalog choice from the env register | yes (choice) |
| 4 | `cloud` | Derived from the app's approved footprint | no (informational) |
| 5 | `region` | Derived from the app's approved footprint | no (informational) |
| 6 | `server_role` | Catalog choice from the role register | yes (choice) |
| 7 | `os` | Catalog choice from the OS register | yes (choice) |
| 8 | `count` | Catalog variable, Dynamic Quantity, bounded by role max | yes (bounded) |
| 9 | `change_reference` | The RITM's linked CHG | no |

The Flow Designer action builds the contract, computes its schema version, and calls the
adapter. If the environment is governed, a missing or unapproved change reference stops here,
in ServiceNow, before the platform is involved ([AD-17](architectural-decisions.md#ad-17-approval-authority-stays-in-servicenow)).

#### Phase 2 — Adapter intake ([AD-02](architectural-decisions.md#ad-02-engine-neutral-run-contract-as-the-integration-seam), [AD-21](architectural-decisions.md#ad-21-single-active-engine-per-run))

1. Authenticate to the target engine with the per-environment service identity.
2. Validate the contract against `schemas/server_request.schema.json`. Closed enums,
   `additionalProperties: false`, `count` bounds. Reject early and cheaply.
3. Compute `fingerprint = sha256(canonical(contract) + catalog_version)`.
4. **Idempotency check.** If `fingerprint.json` already exists for this `request_id`:
   - same fingerprint **and** a run already exists → return the existing `{run_id, run_url}` with
     `200` and `duplicate: true`. **No second dispatch.** This is the "repeated ServiceNow
     request must not create duplicate infrastructure" requirement, discharged at the
     earliest possible point.
   - same `request_id`, **different** fingerprint → `409 CONFLICT`, `REQUEST_MODIFIED`.
     A RITM whose technical fingerprint changed is an approval-integrity problem and must be
     handled by a human, not silently re-run.
5. Resolve the target engine from `configuration/routing/engine_routing.yml` for the
   environment ([AD-09](architectural-decisions.md#ad-09-per-environment-engine-routing)).
6. Persist `request.json` and `fingerprint.json` (immutable, once).
7. **Dispatch**, and record `run_id` + run URL + engine + `correlation_id` **before**
   returning success to ServiceNow.

Step 7's ordering is what makes step 4's duplicate check correct on a retry of step 7.

#### Phase 3 — Resolution (Stage: `resolve`, [AD-03](architectural-didempotency.md §7-configuration-resolver-is-a-python-library-not-jinja), [AD-22](architectural-decisions.md#ad-22-resolver-is-read-only-and-side-effect-free))

Pure. No cloud calls, no writes except to `context.json`.

1. `resolve(request, catalog, as_of)` → resolved configuration + provenance per leaf.
2. Naming engine allocates, by atomic CAS in the run-state store:
   - `short_name[i]` for `i in 1..count` (≤15 chars, NetBIOS-safe, atomic per scope)
   - `fqdn[i]` for `i in 1..count` (the §23 pattern verbatim)
   - `sba_instance_id[i]` — a UUIDv4, minted once, never regenerated ([AD-05](architectural-decisions.md#ad-05-sba_instance_id-is-the-golden-join-key))
3. Image resolver pins a concrete provider image reference from the catalogue, enforcing
   approval status and `expires_at` ([AD-07](architectural-decisions.md#ad-07-image-catalogue-with-pinning-and-expiry)).
4. `TagMapper` produces the provider-shaped metadata set; asserts tag completeness (I-3).
5. Policy gate evaluates §25 policy against the resolved configuration.
6. Write `context.json`: resolved config, allocations, `git_sha`, `ee_digest`, `catalog_version`,
   `correlation_id`, `run_id`.

Any failure here is terminal and cheap: nothing has been created, so `VALIDATION_FAILED` /
`POLICY_BLOCKED` is the whole story. **The most expensive mistakes are made here, while they
are still free.**

#### Phase 4 — Pre-flight validation (Stage: `validate`, §20)

Read-only cloud calls. This is where the resolver's purity is paid for back.

| Check | Failure code | Retryable |
|---|---|---|
| Region available to the identity | `REGION_NOT_AVAILABLE` | no |
| Subnet exists and belongs to the expected VNet/VPC | `NETWORK_MISMATCH` | no |
| Subnet has free IPs ≥ `count` | `SUBNET_IP_EXHAUSTED` | no |
| Quota for the chosen size is sufficient | `QUOTA_EXCEEDED` | no |
| Size is offered in the region | `SIZE_NOT_AVAILABLE_IN_REGION` | no |
| Pinned image exists and is in the expected gallery/project | `IMAGE_NOT_FOUND` | no |
| Image still approved (revocation check) | `IMAGE_REVOKED` | no |
| Management port reachable from the runner subnet | `RUNNER_NOT_REACHABLE` | **yes** (transient) |
| Short names free in the AD domain | `NAME_TAKEN` | no |
| Optional: production change in an approved state | `APPROVAL_FAILED` | no |
| Optional: compliance attestation present for the image | `COMPLIANCE_MISSING` | no |

`IMAGE_REVOKED` deserves a note. `expires_at` gates *selection*; a **revocation** (a security
incident withdrawing an image) must gate *in-flight runs too*. The catalogue therefore has two
distinct fields — `expires_at` (expiry, advisory for in-flight) and `revoked_at` (emergency,
absolute, applies to everything) — and pre-flight checks the latter
([AD-07](architectural-decisions.md#ad-07-image-catalogue-with-pinning-and-expiry)). This is
also the mitigation for [R-07](enterprise-architecture.md#9-architecture-risk-register).

#### Phase 5 — The eight stages (§5)

Stages are the unit of execution, re-entry, retry and reporting
([AD-01](architectural-decisions.md#ad-01-single-entry-playbooks--staged-re-entry)).
Each is independently invocable, reads `context.json`, writes `result.<stage>.json`.

| # | Stage | Provider write? | Target | Idempotency anchor |
|---|---|:--:|---|---|
| 1 | `provision` | yes | Cloud control plane | Cloud resource ID **and** `sba_instance_id` in tags |
| 2 | `os_config` | no (in-guest) | Guest | Module `state:` per task |
| 3 | `validate_os` | no | Guest | Read-only assertions |
| 4 | `domain_join` | AD object | Guest + AD | `sba_instance_id`-derived computer name in AD |
| 5 | `install_agents` | no | Guest + mgmt platforms | Agent service presence + enrolment state |
| 6 | `dns` | DNS record | DNS | Record set content (idempotent upsert) |
| 7 | `cmdb` | CMDB record | ServiceNow | `sba_instance_id` lookup + update in place |
| 8 | `application_onboarding` | out of scope for v1 | — | — |

**Why `provision` and `domain_join` are the two stages with non-trivial idempotency**, and what
"idempotent" concretely means for each:

- `provision` is idempotent because it looks up by `sba_instance_id` in tags first. If a VM
  with that tag exists, it is adopted (validated against the desired spec) rather than a
  second one created. This is the single most important behaviour in the platform: it is what
  makes a re-run after a crash at minute 12 safe ([idempotency.md §7 ](idempotency.md#7-per-stage-idempotency-contract)).
- `domain_join` is idempotent because it queries the domain for the computer object first.
  Already joined → verify OU and GPO link, change if needed, no re-join. Re-joining an already
  joined machine breaks it. It also handles the **orphan** case: a computer object from a
  previous run that was never joined, which must be deleted or reused rather than collided
  with.
- `dns` is idempotent by idempotent upsert, and additionally must handle **name reuse**: if a
  record already points at a *different* IP, that is a conflict requiring a decision
  (`DNS_RECORD_CONFLICT`, non-retryable), never a silent overwrite.
- `cmdb` is idempotent by `sba_instance_id` lookup + update-in-place, so a rebuild updates the
  existing CI record rather than creating a duplicate ([AD-05](architectural-decisions.md#ad-05-sba_instance_id-is-the-golden-join-key)).

**`serial` and batching ([C-15](architectural-decisions.md#2-requirement-conflict-register)).** `provision` and every
post-build stage run with a configurable `serial` (default `1` in prod, configurable upward
where the estate and quota allow). A host failure does not abort the batch: the remaining hosts
are attempted, and the aggregate becomes `PARTIAL`. Stopping the batch at the first failure
loses the information about which other hosts are fine, and forces an unnecessary re-run.

**Stage sequencing with reboots.** Windows baseline may require one or more reboots. The
reboot is an explicit task with `register` + `win_reboot_pending` handling, and the stage does
not proceed past a reboot until WinRM is confirmed back. Reboot handling is *inside* the Windows
role — it is not the stage machine's problem and the stage machine has no Windows-specific
branch ([logical-architecture.md §2.7 ](logical-architecture.md#27-l3--os--post-build)).

#### Phase 6 — Reporting ([AD-14](architectural-decisions.md#ad-14-result-delivery-via-artifacts-never-log-scraping))

The reporter builds `run_result.json` — per-stage, per-host, with error codes, timings, the
resolved-config *summary*, image version, `git_sha` and `ee_digest` — and a human-readable
build report. Then:

- write `run_result.json` to the run-state store,
- upload as a CI artifact where the engine supports it,
- set the playbook exit code from the aggregate status (non-zero unless `SUCCESS`),
- emit the ServiceNow callback (P2) with the terminal status,
- release the environment concurrency semaphore.

**The callback is emitted even on failure**, including on unexpected exceptions. A run that
fails without telling ServiceNow is a RITM that sits "In Progress" forever — the exact failure
[enterprise-architecture.md §6 ](enterprise-architecture.md#6-integration-view)'s reconciliation
job exists to catch, but the callback should make it unnecessary.

---

## 4. Stage Re-Entry and Resumption

The property that makes §5's "each stage independently executable" real.

```
  Run 1:  resolve ✓  validate ✓  provision ✓(2/2)  os_config ✗(h1)  → PARTIAL
          context.json: names, ids, image pin, instance_ids[2]
          result.provision.json: SUCCESS (2/2)
          result.os_config.json: PARTIAL (h1 FAILED DOMAIN_UNREACHABLE, h2 SUCCESS)

  Operator: fixes the network route, re-runs stage 2 only.

  Run 2:  server_build.yml --stage os_config
          adapter: existing correlation_id, NEW run_id
          resolve:  re-read from context.json — **no re-allocation** (names/ids are durable)
                    re-verify image is still approved
          provision: SKIPPED (result.provision.json already SUCCESS)
          os_config: re-runs for h1 only (h2 already SUCCESS in the prior result)
          ...
          → SUCCESS, and ServiceNow is told the request completed
```

Rules that make this safe:

| Rule | Reason |
|---|---|
| Re-running a stage never re-allocates names or IDs | Allocation is durable in `context.json`; re-allocation would orphan the first allocation |
| A stage that already has a `SUCCESS` result is skipped unless `force: true` | Prevents accidental rework; `force` is an explicit operator action, logged |
| A stage re-run recomputes its own pre-flight | Conditions may have changed since the last run |
| `correlation_id` is preserved, `run_id` is new | "Same build, second attempt" must be distinguishable from "same attempt" |
| Stage results accumulate, they do not overwrite | Full history per stage: `{attempt, run_id, ts, status, per_host[]}` |

---

## 5. Failure Branches

```
                              any stage fails
                                    |
                    +---------------+---------------+
                    |                               |
            infra not yet created          infra exists (partial)
            (Stage 1 failed)               (Stages 2-7 failed)
                    |                               |
                    v                               v
        classify error_code                     classify error_code
                    |                               |
        +-----------+-----------+       +-----------+-----------+
        |                       |       |                       |
   retryable               terminal                  retryable  terminal
   (QUOTA? no;              (POLICY_   <-- auto        (UNREACHABLE  (POLICY_,
    UNREACHABLE yes)         VIOLATION      retry       yes)         AGENT_FAIL)
        |                    NO retry)      limited          |            |
        v                                     times            v            v
   bounded retry                      infrastructure      bounded     RETAIN infra
   exponential backoff                RETAINED,           retry       [AD-16]
   [failure-and-retry.md]             PARTIAL,                            |
                                     Manual Attention                       v
                                          |                        Manual Attention
                                          v                        + remediation
                                 remediation: re-run                  re-run stage
                                 the failed stage only
                                 (idempotent)
```

### 5.1 The three terminal outcomes and what ServiceNow does

| Outcome | ServiceNow | Infrastructure | Human action |
|---|---|---|---|
| `VALIDATION_FAILED` / `POLICY_BLOCKED` | RITM → "Failed - Configuration", work note with the specific rule id and the actionable message | none | Fix the request or the catalogue |
| `FAILED` on Stage 1 | RITM → "Failed", work note with error code | none (or a partial VM, cleaned up) | Re-raise or remediate |
| `PARTIAL` (Stages 2-7) | RITM → "Manual Attention" (**not** "Failed"), work note listing exactly which hosts and which stage, plus the remediation command | **retained** | Follow the runbook, re-run one stage ([AD-16](architectural-decisions.md#ad-16-forward-fix-over-auto-destroy)) |

`PARTIAL` mapping to a *distinct* ServiceNow state is not cosmetic. If `PARTIAL` mapped to
"Failed", the standard remediation instinct is to delete and re-raise the RITM — which
destroys the link to retained infrastructure and orphans the DNS and AD objects. The
distinction must be visible in the catalog, in the RITM state set, and in the work note.

### 5.2 Failure of post-build stages after partial success within a stage

For `count: 2` where domain join succeeds on host 1 and fails on host 2:

- `result.domain_join.json` records both hosts' outcomes,
- the stage status is `PARTIAL`,
- CMDB registration (Stage 7) still runs for the hosts that are healthy — **a joined, patched
  server that is not in the CMDB is invisible and unmanaged, which is worse than one that is
  half-built**, so CMDB registration is not gated on every host succeeding,
- DNS registration (Stage 6) runs for healthy hosts only; it is a per-host resource, not a
  fleet-wide one,
- the RITM reports `PARTIAL` with the per-host breakdown.

This is the concrete meaning of "forward-fix, not auto-destroy": **maximise the number of
correctly-built, correctly-registered servers, and make the remainder visible.** A batch that
builds 1 of 2 and reports honestly is a good outcome; a batch that builds 0 of 2 because it
rolled back, or that builds 1 and claims success, are both failures.

---

## 6. Retry and Cancellation

### 6.1 Retry

Two layers, deliberately separated by scope ([failure-and-retry.md](failure-and-retry.md)).

| Layer | Scope | Mechanism | Used for |
|---|---|---|---|
| Task level | One task, one host | `until` / `retries` / `delay` inside a role | Cloud API timeout, port not yet open, agent service start |
| Stage level | One stage, all hosts | Stage wrapper re-invokes the stage with a new `run_id` | Boot not complete, WinRM not ready, DNS propagation, AD replication lag |

Stage-level retry reuses `correlation_id`, mints a new `run_id`, and appends to the stage's
attempt history. Bounded (default 3) with exponential backoff and jitter. Non-retryable
classes are never retried regardless of count — retrying `POLICY_VIOLATION` three times just
delays a clear error by fifteen minutes.

### 6.2 Cancellation

Cancellation is an **authorised human action**, not an automatic response to a failure.

```
  Operator cancels (ServiceNow task action or platform CLI)
        |
        v
  Adapter sets run_state.cancel_requested = true
        |
        v
  Engine: cancel the in-flight job (GHA: POST /actions/runs/{id}/cancel)
          (AAP: POST /api/controller/jobs/<id>/cancel/)
        |
        v
  Stage wrapper's termination handler runs:
        - write result.<stage>.json with CANCELLING→CANCELLED and which hosts completed
        - release the concurrency semaphore
        - emit the callback so ServiceNow updates immediately
        - DO NOT destroy provisioned infrastructure
        |
        v
  RITM → "Cancelled (Manual Attention)"; runbook decides the fate of what exists
```

Two deliberate properties: **cancellation never destroys infrastructure** (an operator
cancelling at minute 30 usually wants the partially built server for inspection, and
destruction is a separate, explicit, approved act), and **cancellation always reports state**
(so a cancelled run is never a silent one). Races between cancel and natural completion are
resolved by the terminal write in the run-state store being a compare-and-swap: the first
terminal state wins and the second is recorded as a no-op.

---

## 7. Status Propagation to ServiceNow

Two independent paths, because both can fail
([enterprise-architecture.md §6 ](enterprise-architecture.md#6-integration-view)).

```
  PATH A — callback (P2), primary for terminal state
     Engine/Adapter ──HTTPS + OAuth2──▶ ServiceNow (MID Server transform, or
                                         a Scripted REST API with OAuth)
     Payload: {request_id, correlation_id, run_id, stage, status, error_code?,
               servers[], image_version, run_url, build_duration_s}
     Authenticated + signature-verified. Idempotent on
     (request_id, stage, status, attempt_seq). Unsigned/mismatched → rejected and logged.

  PATH B — status polling (P1), primary for in-progress visibility
     Flow Designer subflow polls the engine with backoff
     (30s, 60s, 120s, 300s, 300s, …) and updates the RITM work note with
     current stage and elapsed time. Backoff, not a tight loop: the platform
     deliberately does not implement a websocket, and a tight poll is rude to
     both engines.
```

### 7.1 Why the RITM never contains the technical result in full

ServiceNow gets a **summary**, not `context.json`:

| Sent to ServiceNow | Not sent |
|---|---|
| `sba_instance_id`, hostname, FQDN, private IP | Subscription / project IDs |
| Cloud resource ID | VPC / VNet / subnet IDs and CIDRs |
| `image_version` (e.g. `windows-2025-v12.3`) | Image resource IDs |
| `os_version`, patch level | Domain names beyond the FQDN, OU paths |
| Policy names applied | Security group / NSG rule details |
| `resolved_config_hash` | The full resolved configuration |
| `git_sha`, `ee_digest`, run URL | Any credential (none exist) |

Rationale: the RITM is visible to a much wider audience than the run-state store, it is
exportable through reporting, and it is indexed for search. Distributing full infrastructure
topology into that surface is a data-classification decision we should not make by default.
The full record stays in the run-state store, and `resolved_config_hash` makes the linkage
verifiable: an auditor can confirm the RITM and the stored context correspond without the
topology leaving the store.

---

## 8. Status Reconciliation

The safety net. A ServiceNow scheduled job, every N minutes (default 5):

```
  for each RITM in states {Approved, Scheduled, In Progress, Implementing}
      1. read run-state /result for request_id
      2. if no run state        -> the request never dispatched.
                                    (alert: this is a ServiceNow-side failure)
      3. if state is terminal   -> align the RITM state + work note
      4. if state is not terminal and the engine reports no live run
                                -> the engine job was lost (runner died, controller
                                   restart, cancellation outside the platform).
                                    Mark 'Manual Attention' with the last known stage.
      5. if state is not terminal and the engine run is live
                                -> refresh the work note (stage, elapsed, host counts)
```

This converts every possible "stuck RITM" into either a correction or a paged human within one
interval, rather than a silent indefinite hang. It is deliberately **independent of the Flow
Designer logic** — a bug in a subflow must not be able to hide a running build
([R-09](enterprise-architecture.md#9-architecture-risk-register)).

---

## 9. Idempotency Guarantees

The complete set, and the layer that discharges each. Full detail:
[idempotency.md](idempotency.md).

| # | Guarantee | Discharged by | Where |
|---|---|---|---|
| G-1 | A repeated identical ServiceNow request never dispatches a second run | Fingerprint check in the adapter | Phase 2 |
| G-2 | A retried dispatch after a partial failure does not double-dispatch | `run_id` recorded before the success return | Phase 2 |
| G-3 | Re-running `provision` never creates a second VM | Tag lookup by `sba_instance_id` before create | Stage 1 |
| G-4 | Re-running any stage is safe | Stage result skip + per-task `state:` | All stages |
| G-5 | A failed batch does not lose the hosts that succeeded | Per-host result capture; roll-up to `PARTIAL` | Reporter |
| G-6 | Name/ID allocation is never duplicated | CAS on the sequence counter | Resolution |
| G-7 | A cancelled-then-retried run does not double-write terminal state | CAS on the terminal write in `run_result.json` | Reporter |
| G-8 | A duplicate callback is a no-op | Idempotency key on the callback | Adapter |
| G-9 | A rebuild of a logical server updates CMDB rather than duplicating it | `sba_instance_id` upsert | Stage 7 |

G-3 and G-6 are the two that prevent real-world duplicate infrastructure. G-1 prevents the
common case; G-3 prevents the case that survives G-1 (a crash *after* dispatch, where the
request is legitimately re-raised).

---

## 10. Sequence View — Successful Build, `count: 2`

```
SN     Adapter    StateStore   AAP          validate   provision  os_win   domain   dns    cmdb
 |        |            |        |              |          |         |        |       |      |
 |--build>|            |        |              |          |         |        |       |      |
 |        |-persist--->|        |              |          |         |        |       |      |
 |        |-launch---> |--POST->|              |          |         |        |       |      |
 |        |<-202 jobid--|        |              |          |         |        |       |      |
 |<--202---|            |        |              |          |         |        |       |      |
 |        |            |<--resolve--write context, allocate names/ids/uuids--->|       |      |
 |        |            |        |-job------->|          |         |        |       |      |
 |        |            |        |             |-quota/net/image (read-only)->|       |      |
 |        |            |        |             |          |         |        |       |      |
 |        |            |        |             |          |-h1----->|        |       |      |
 |        |            |        |             |          |<-ok-----|        |       |      |
 |        |            |        |             |          |-h2----->|        |       |      |
 |        |            |        |             |          |<-ok-----|        |       |      |
 |        |            |        |             |          |  (serial: 1,  h2 not started on h1 fail)
 |        |            |        |             |          |         |-h1---->|       |      |
 |        |            |        |             |          |         |-h2---->|       |      |
 |        |            |        |             |          |         |        |-h1--->|      |
 |        |            |        |             |          |         |        |-h2--->|      |
 |        |            |        |             |          |         |        |     |-h1-->|
 |        |            |        |             |          |         |        |     |-h2-->|
 |        |            |        |             |          |         |        |     |     |-h1->|
 |        |            |        |             |          |         |        |     |     |-h2->|
 |        |            |        |             |          |         |        |     |     |<-write result.provision/os/domain/dns/cmdb
 |        |            |        |             |          |         |        |       |      |
 |        |            |        |             |          |         |        |       |      |-rollup -> SUCCESS
 |        |            |        |             |          |         |        |       |      |
 |        |<-----callback (P2): SUCCESS, servers[2], image_version, run_url-----|       |      |
 |-update RITM, work note, close task-------------------------------------------|       |      |
```

---

## 11. Timeline and Budgets

Planning targets used for SLA design, timeouts and user expectations. Values are configurable
per environment; the defaults assume a hardened golden image and a warm runner pool.

| Phase | Typical | p95 budget | Timeout policy | Retryable |
|---|---:|---:|---|---|
| ServiceNow intake → dispatch | < 5 s | 30 s | adapter: 3× short | auth / network |
| Dispatch → runner start | 10–60 s | 5 min | engine-managed | yes |
| Resolve | < 1 s | 10 s | no | no |
| Pre-flight | 5–20 s | 2 min | 3× | `RUNNER_NOT_REACHABLE` only |
| Stage 1 `provision` / host | 60–120 s | 10 min | per-host | yes |
| Stage 2 `os_config` (Windows) | 10–20 min | 45 min | per-host | yes (reboot) |
| Stage 2 `os_config` (Linux) | 4–8 min | 20 min | per-host | yes |
| Stage 3 `validate_os` | 1–2 min | 5 min | — | yes |
| Stage 4 `domain_join` | 3–8 min | 20 min | per-host | yes (replication lag) |
| Stage 5 `install_agents` | 5–10 min | 25 min | per-host | yes |
| Stage 6 `dns` | 30 s | 5 min | — | yes (propagation) |
| Stage 7 `cmdb` | 10 s | 2 min | 3× | yes |
| Report + callback | 5 s | 30 s | 3× | yes |
| **Total, `count: 1`, prod** | **~35–60 min** | **~2.5 h** | | |
| **Total, `count: 4`, prod, serial 1** | **~2.5–4 h** | **~10 h** | | |

`count > 4` in production is a genuine operational question, not a technical one. It is
handled by policy: either the per-role batch cap is raised, or `serial > 1` is permitted for
stateless roles, or a nonprod environment is used for large fleets. Surfacing this as a policy
decision early is much cheaper than discovering it during a batch failure.

---

## 12. Next

- Resolution hierarchy and pre-flight detail: [configuration-resolution.md](configuration-resolution.md)
- Idempotency mechanics: [idempotency.md](idempotency.md)
- Error codes and retry classification: [failure-and-retry.md](failure-and-retry.md)
- ServiceNow field mapping and callbacks: [api-contract.md](../api/api-contract.md)
- Runbooks for the three terminal outcomes: [../runbooks/](../runbooks)
