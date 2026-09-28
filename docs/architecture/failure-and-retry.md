# Failure and Retry Architecture

Status: **Phase 1 — Proposed**

Error taxonomy, classification, retry at two layers, compensation, batch failure semantics,
timeout design, and the error messages a requester actually sees.

Related: [idempotency.md](idempotency.md), [api-contract.md §3 ](../api/api-contract.md#3-error-model),
[request-lifecycle.md §5 ](request-lifecycle.md#5-failure-branches).

---

## 1. Principles

| # | Principle | Consequence |
|---|---|---|
| F-1 | **Classify before acting** | Every failure gets a code and a `retryable` classification before any decision is taken ([api-contract.md §3.2 ](../api/api-contract.md#32-error-code-registry)) |
| F-2 | **Retry only what can succeed on a second attempt** | A retry of a `POLICY_VIOLATION` does not become valid, it just takes longer to fail |
| F-3 | **Retry close to the cause** | Task-level for a transient condition; stage-level only for a whole-stage transient condition |
| F-4 | **Never destroy on failure by default** | [AD-16](architectural-decisions.md#ad-16-forward-fix-over-auto-destroy) |
| F-5 | **Partial success is a first-class outcome** | Not an error case; it is the normal result of a batch where some hosts succeeded |
| F-6 | **Fail closed** | An unclassified failure is treated as non-retryable and retained. Never optimistically retried |
| F-7 | **Every failure produces an actionable message** | `actionable` is a required field, not a nicety |
| F-8 | **Bounded, always** | No unbounded retry, on any layer |

---

## 2. Error Taxonomy

Seven categories. The category determines the default retry behaviour, so classification is
mostly a matter of putting the error in the right category.

| Category | Definition | Default | Examples |
|---|---|---|---|
| **CONTRACT** | The request is malformed or invalid | no retry, no infrastructure | `SCHEMA_INVALID`, `UNSUPPORTED_ENUM_VALUE`, `CONTRACT_FORBIDDEN_FIELD` |
| **RESOLUTION** | Configuration could not be resolved | no retry, no infrastructure | `NO_APPROVED_CONFIGURATION`, `PRECEDENCE_CONFLICT`, `IMAGE_NOT_FOUND`, `NAME_UNRESOLVABLE` |
| **POLICY** | Resolved, but forbidden | no retry, no infrastructure | `POLICY_VIOLATION`, `APPROVAL_FAILED`, `CHANGE_FREEZE_ACTIVE`, `COMPLIANCE_MISSING` |
| **CAPACITY** | The cloud cannot currently do it | **no retry** — retrying a quota is futile; the condition is administrative | `QUOTA_EXCEEDED`, `SUBNET_IP_EXHAUSTED`, `SIZE_NOT_AVAILABLE_IN_REGION` |
| **TRANSIENT** | A temporary environmental condition | **retry** with exponential backoff | `CLOUD_API_TIMEOUT`, `CLOUD_API_THROTTLED`, `HOST_UNREACHABLE`, `WINRM_NOT_READY`, `DNS_PROPAGATION_TIMEOUT`, `AGENT_NOT_REPORTING` |
| **EXTERNAL-DEP** | A dependency the platform does not control | **retry**, then escalate | `STATE_STORE_UNAVAILABLE`, `EE_UNAVAILABLE`, `SOURCE_UNAVAILABLE`, `IDENTITY_UNAVAILABLE` |
| **CONFIGURATION-ERROR** | A defect in the platform or its configuration | no retry, escalate, fix forward | `RESOLVER_ERROR`, `INTERNAL_ERROR`, `TAG_WRITE_INCOMPLETE` |

Two classifications are deliberately counter-intuitive and worth stating explicitly:

**CAPACITY is not retryable.** §22 lists "quota exceeded" under *do not retry*, and it is right:
a quota does not restore itself within a retry window, so retrying is pure delay. But
`CLOUD_API_THROTTLED` **is** retryable, and it is often reported as a quota error by cloud APIs.
The distinction is whether the limit is a *sustained* allocation (retry futile) or a
*rate* limit that clears in seconds (retry works). Getting this backwards either wastes
fifteen minutes on a doomed retry, or gives up on a request that would have succeeded in thirty
seconds.

**EXTERNAL-DEP is retryable but must escalate.** If the run-state store is unreachable, the
platform cannot record its own state, which means it cannot guarantee idempotency for that run.
Retrying is right; retrying *forever* while creating infrastructure is not. A `STATE_STORE_
UNAVAILABLE` after the retry budget is exhausted must stop the run before any mutation, because
continuing without durable state would break
[G-5](idempotency.md#3-guarantees) and [G-6](idempotency.md#3-guarantees).

---

## 3. Where Failures Are Caught

| Layer | Mechanism | Emits |
|---|---|---|
| Role task | `block`/`rescue`/`always`; `until` for transient conditions | A task-level result |
| Role | A `rescue` mapping a module failure to a registered `error_code` | A role-level result |
| Stage wrapper | Reads the role results; aggregates per host; writes `result.<stage>.json` | A stage result |
| Failure router | Classifies; decides retry / retain / destroy; sets the terminal status | A request status |
| Reporter | Rolls up; builds `run_result.json`; sets the exit code | The final result |
| Engine | Maps the exit code to a job conclusion | Transport status |
| Adapter | Reads the artifact; maps to a callback | The ServiceNow update |

**A role must not decide a request-level outcome.** A role reports what happened; the stage
wrapper aggregates; the reporter rolls up. If a role could set the terminal status, the same
role would behave differently depending on which stage invoked it — and the status model would
stop being derivable from the artifacts.

---

## 4. Retry Classification

The decision table. `retryable` in the registry is the authoritative value; this is the
rationale.

### 4.1 Retryable — and why

| Code | Why a retry can succeed | Max | Backoff |
|---|---|:--:|---|
| `CLOUD_API_TIMEOUT` | The provider did not respond in time; the operation may or may not have been applied — which the idempotency layer handles | 5 | 5, 15, 45, 135, 405 s |
| `CLOUD_API_THROTTLED` | A rate limit clears in seconds | 6 | 5, 10, 20, 40, 80, 160 s |
| `RESOURCE_CONFLICT` | An optimistic-concurrency conflict resolves on re-read | 4 | 3, 9, 27, 81 s |
| `HOST_UNREACHABLE` | The guest agent is not up yet; WinRM/SSH is not listening | 8 | 15, 30, 60, 60, 120, 120, 180, 180 s |
| `WINRM_NOT_READY` | WinRM starts after boot; a reboot restarts it | 10 | 30, 30, 60, 60, 60, 90, 90, 120, 120, 120 s |
| `SSH_NOT_READY` | sshd starts after boot; a reboot may stop it | 10 | as above |
| `GUEST_AGENT_TIMEOUT` | WinRM/SSH goes unresponsive during a long package operation | 4 | 30, 60, 120, 240 s |
| `REBOOT_TIMEOUT` | A Windows reboot with a long pending-reboot chain | 6 | 60, 60, 120, 120, 180, 180 s |
| `DOMAIN_DC_UNREACHABLE` | A specific DC is down or unreachable; another may answer. AD replication lag after a new build is common | 4 | 30, 60, 120, 240 s |
| `DOMAIN_JOIN_TIMEOUT` | Replication of the new computer object to the DC that will be used | 4 | 30, 60, 120, 240 s |
| `AGENT_INSTALL_FAILED` | The internal package source was briefly unavailable | 3 | 30, 60, 120 s |
| `AGENT_NOT_ENROLLED` | The management platform is processing the enrolment | 4 | 30, 60, 120, 240 s |
| `AGENT_NOT_REPORTING` | Heartbeat propagation delay | 4 | 60, 120, 240, 300 s |
| `DNS_PROPAGATION_TIMEOUT` | Authoritative servers refresh on a TTL | 3 | 30, 60, 120 s |
| `CMDB_WRITE_FAILED` | A transient ServiceNow or MID Server failure | 3 | 15, 30, 60 s |
| `STATE_STORE_UNAVAILABLE` | Transient storage outage — **stops before any mutation if it persists** | 3 | 10, 30, 60 s |
| `EE_UNAVAILABLE` | A registry or pull failure | 2 | 30, 60 s |
| `SOURCE_UNAVAILABLE` | A transient GitHub or SCM outage | 3 | 15, 30, 60 s |
| `IDENTITY_UNAVAILABLE` | An OIDC exchange or token refresh failure | 3 | 10, 30, 60 s |
| `RUNNER_NOT_REACHABLE` | A transient network path problem between the runner and the target subnet | 3 | 15, 30, 60 s |

### 4.2 Not retryable — and why

| Code | Why a retry cannot help | What happens instead |
|---|---|---|
| All CONTRACT codes | The request is invalid; time does not change it | `VALIDATION_FAILED`; the requester is told which field |
| All RESOLUTION codes | The configuration is wrong or absent | `VALIDATION_FAILED`; an operator fixes the catalogue. A repeat RITM with the same contract produces the same failure — deterministically |
| All POLICY codes | A deliberate control rejected it | `POLICY_BLOCKED`; the requester is told the rule, the floor, and the remediation |
| `QUOTA_EXCEEDED` | A quota is an administrative change | `VALIDATION_FAILED` with the owning team and the requested amount. Retrying delays a clear answer |
| `SUBNET_IP_EXHAUSTED` | An IP range is a finite resource | `VALIDATION_FAILED` with the current and requested counts |
| `SIZE_NOT_AVAILABLE_IN_REGION` | A catalogue fact | `VALIDATION_FAILED` |
| `DOMAIN_CREDENTIAL_INVALID` | The credential is wrong; retries multiply failed logon attempts, which can **lock the account** | `FAILED`; an alert on the join account. This is a real harm from an incorrect retry classification |
| `DOMAIN_OU_NOT_FOUND` | The OU does not exist | `FAILED`; a configuration error in the catalogue |
| `DNS_RECORD_CONFLICT` | A record points at a different IP. **Silently overwriting could take a live service offline** | `FAILED`; a human decides. Never auto-resolve |
| `CMDB_DUPLICATE_DETECTED` | Two records claim the same identity — a data-integrity problem | `FAILED`; a human resolves |
| `TAG_WRITE_INCOMPLETE` | A permission or quota problem in the tag API | `FAILED`. **Never proceed** with incomplete metadata: it breaks inventory, cost attribution and audit simultaneously |
| `OS_VERSION_MISMATCH` | The image is not what was pinned | `FAILED`; the image pipeline is notified |
| `BASELINE_DRIFT` | Compliance is not met and remediation did not achieve it | `FAILED`; a compliance review, not a retry |
| `IMAGE_REVOKED` | A security withdrawal | `FAILED` immediately, at pre-flight |
| `RESOLVER_ERROR`, `INTERNAL_ERROR` | A platform defect | `FAILED`; a page. Retrying a code defect just delays the page |
| `TIMEOUT` | The stage budget was exhausted | `FAILED` with the stage named, so a human can decide to raise it or re-run that stage |

**`DOMAIN_CREDENTIAL_INVALID` and `DNS_RECORD_CONFLICT` are the two that a naive
implementation gets wrong**, because both are tempting to retry. The first can lock a service
account; the second can take a production hostname away from a running service. Both are
classified as terminal for that reason, and both have an operational consequence that makes a
human the right responder.

---

## 5. Retry at Two Layers

```
  ┌───────────────────────────────────────────────────────────────────┐
  │  STAGE-LEVEL RETRY                        (the stage wrapper)      │
  │                                                                   │
  │   attempt 1 ── FAILED (TRANSIENT) ──▶ backoff ──▶ attempt 2       │
  │   attempt 2 ── FAILED (TRANSIENT) ──▶ backoff ──▶ attempt 3       │
  │   attempt 3 ── exhausted            ──▶ terminal PARTIAL/FAILED  │
  │                                                                   │
  │   new run_id, SAME correlation_id, appended to the stage history   │
  └───────────────────────────────────────────────────────────────────┘
              ▲                    ▲
              │                    │
  ┌───────────┴────────────────────┴──────────────────────────────────┐
  │  TASK-LEVEL RETRY                                (inside a role)  │
  │                                                                   │
  │   until: <condition>                                              │
  │   retries: 5    delays: 5   (or a task-specific schedule)         │
  │                                                                   │
  │   same run_id, same attempt                                       │
  └───────────────────────────────────────────────────────────────────┘
```

| Aspect | Task level | Stage level |
|---|---|---|
| Scope | One task, one host | One stage, all its hosts |
| Mechanism | `until` + `retries` + `delay` in the role | The stage wrapper re-invokes the stage |
| Budget | Seconds to ~10 minutes | Minutes to ~30 minutes |
| New `run_id`? | No | **Yes** |
| New `attempt` in the stage result? | No | **Yes** |
| `correlation_id` | Unchanged | **Unchanged** |
| Used for | Cloud API timeouts, port-not-yet-open, an agent service starting | Boot not complete, WinRM not ready, DNS propagation, AD replication lag |
| Failure to escape | The task fails, the role's `rescue` classifies | The attempt is recorded; the next begins |

**Why the distinction matters for audit.** A `run_id` per *attempt* and a `correlation_id` per
*build* means "did we try this three times?" and "which stages belong to this request?" are both
answerable ([enterprise-architecture.md §5.1 ](enterprise-architecture.md#51-correlation-model)).
Collapsing them into one identifier loses the ability to distinguish a slow build from a
repeatedly failing one, and those need different responses.

### 5.1 Backoff

Exponential with full jitter, because synchronised retries from several hosts against one
service are how a retry policy becomes an outage.

```
  delay(n) = random(0, min(cap, base * 2^n))

  base = 5s,  cap = 300s
```

Full jitter (a uniform random value up to the computed delay) rather than a fixed exponential
curve, because jitter is what de-synchronises a `serial: 1` batch where every host fails at the
same step. A fixed curve keeps them in lockstep and each retry wave re-creates the load.

**Total retry budget per stage** is also capped, independently of the per-task budgets:

| Environment | Stage retry budget | Rationale |
|---|---|---|
| dev | 3 attempts, ~5 min | Fail fast; a developer is watching |
| nonprod | 3 attempts, ~10 min | Exercise the retry path without long waits |
| prod | 3 attempts, ~30 min | Transient AD/DNS/agent conditions genuinely take this long in a large enterprise |

Beyond the budget, the stage is terminal and the request becomes `PARTIAL` (infrastructure
retained) or `FAILED`. A production build that has been retrying for an hour is a human
decision, not an automated one.

---

## 6. Batch and Partial Failure Semantics

`count: 4`, with `serial: 1`, and host 2 failing domain join.

```
  host 1  provision      SUCCESS
  host 1  os_config      SUCCESS
  host 1  domain_join    SUCCESS
  host 2  provision      SUCCESS
  host 2  os_config      SUCCESS
  host 2  domain_join    FAILED  DOMAIN_DC_UNREACHABLE (retries exhausted)
          │
          ▼  serial continues — hosts 3 and 4 are still attempted
  host 3  ...            SUCCESS
  host 4  ...            SUCCESS
          │
          ▼
  result.domain_join  : PARTIAL   (1 failed, 3 succeeded)
  result.dns          : SUCCESS   (per-host; runs for healthy hosts)
  result.cmdb         : SUCCESS   (healthy hosts registered)
  run_result          : PARTIAL
  RITM                : Manual Attention
```

### 6.1 Why the batch continues after a failure

Stopping at the first failure loses the information about which other hosts are fine, and forces
a re-run of work that already succeeded. Continuing:

- maximises the number of correctly built, correctly registered servers,
- produces a per-host result set that tells the operator exactly what to fix,
- keeps the `PARTIAL` classification honest.

The cost is compute spent on hosts that will also need remediation. That is the right trade:
orphaned, unregistered, unmonitored servers are more expensive than compute
([AD-16](architectural-decisions.md#ad-16-forward-fix-over-auto-destroy)).

### 6.2 Which stages continue after a partial failure

| Stage | Continues for healthy hosts? | Reason |
|---|:--:|---|
| `provision` | **Yes** | Each host is independent |
| `os_config` | **Yes** | Independent per host |
| `validate_os` | **Yes** | Read-only per host |
| `domain_join` | **Yes** | Independent per host; AD can hold both a joined and an unjoined object |
| `install_agents` | **Yes** | Agents on healthy hosts are still wanted |
| `dns` | **Yes**, and only for healthy hosts | A record for a host that failed domain join would advertise an unmanaged server |
| `cmdb` | **Yes**, and only for hosts that reached Stage 4 successfully | **A joined, patched, monitored server that is not in the CMDB is invisible and unmanaged** — worse than one that is half-built. CMDB registration is not gated on every host succeeding |

That last row is the most important one, and it is a deliberate inversion of the intuitive
"abort downstream work on upstream failure". The intuition is right for *fleet-level* resources
and wrong for *per-host* resources. A DNS record and a CMDB record are per-host; gating them on
the whole batch leaves successfully built servers unmanaged, which is precisely the outcome an
enterprise CMDB exists to prevent.

### 6.3 Roll-up

```
  host status  = SUCCESS | FAILED | UNREACHABLE | SKIPPED | ROLLED_BACK

  stage status:
      all in {SUCCESS}                 -> SUCCESS
      >=1 SUCCESS and >=1 FAILED       -> PARTIAL
      all FAILED                       -> FAILED
      all SKIPPED                     -> SKIPPED

  request status:
      all stages SUCCESS              -> SUCCESS
      some SUCCESS, some PARTIAL/FAILED, at least one stage produced
        infrastructure                -> PARTIAL          (infrastructure retained)
      failure before any infrastructure -> FAILED
      failure at validate             -> VALIDATION_FAILED
      failure at the policy gate      -> POLICY_BLOCKED
      cancelled                       -> CANCELLED
```

`PARTIAL` requires at least one `SUCCESS` **and** the existence of infrastructure. A single-host
build that fails at Stage 4 is `FAILED` with infrastructure retained, not `PARTIAL` — the label
is for batches, and reserving it for batches keeps it meaningful.

---

## 7. Compensation

### 7.1 Policy

| Situation | Compensation | Rationale |
|---|---|---|
| `provision` fails partway | **Destroy the partial instance** if the create failed; if the create succeeded and something later in the stage failed, retain | A VM whose NIC or disk attachment failed is junk. A VM that was created successfully is not |
| Post-provision stage fails | **Retain.** Never auto-destroy ([AD-16](architectural-decisions.md#ad-16-forward-fix-over-auto-destroy)) | Domain objects, DNS records and CMDB records would be orphaned; those cost more than the compute |
| `dns` fails for one host | Roll back only that host's record **if it was created by this run** | Removing a pre-existing record would be destructive |
| `cmdb` fails | Roll back the CI record **if this run created it**; never roll back an update to a pre-existing record | A rebuild updates in place; deleting it would lose the business record |
| `domain_join` fails | Clean up the computer object **only if this run created it**; if it adopted a pre-existing object, leave it | Removing a pre-existing object would break whatever else uses it |
| `destroy` stage fails | Partial teardown is reported per resource; the run-state records exactly what remains | A teardown that hides its own partial failure is the worst kind |

**The rule behind all of these:** compensation may undo what *this run* created, and nothing
else. Anything the platform did not create, it does not delete. This is the discipline that
makes an automated destroy safe to run against a production estate where some resources
predate the platform.

### 7.2 Destroy is a separate, approved operation

```yaml
lifecycle:
  on_failure: retain          # retain | destroy
```

| Environment | Default | Destroy requires |
|---|---|---|
| dev | `retain` (with `destroy` available) | A policy flag |
| nonprod | `retain` | A policy flag + a documented change |
| prod | `retain` | **A separate, approved ServiceNow request** |

Teardown of production infrastructure is a governed act, not a consequence of a failed build.
A build that fails at Stage 6 and takes the server with it would also take the DNS record and
the CMDB relationship into an inconsistent state, and would destroy the very evidence needed
to diagnose the failure.

---

## 8. Timeouts

| Timeout | Where | Value | Consequence |
|---|---|---|---|
| Adapter HTTP request | Adapter | 30 s | Retry 3× |
| Engine dispatch | Adapter | 30 s | Retry 3×; idempotent |
| Stage (whole) | Stage wrapper | Per stage, per environment | `TIMEOUT` with the stage named |
| Cloud API call | Task | Module default, or explicit | Task-level retry |
| Host unreachable | Task | Per code (§4.1) | Task-level retry |
| WinRM/SSH ready | Task | Per code | Task-level retry |
| Reboot complete | Task | 30 min for Windows | Task-level retry |
| Job (AAP) | Job template | > the approval dwell time + the stage budget | `never ran` if it expires before execution |
| Job (GHA) | Workflow | > the stage budget | `timed_out` |
| Environment concurrency wait | Semaphore | Configurable | The run waits; a `QUEUED` state, not a failure |

**The `never ran` vs `failed` distinction is load-bearing.** An AAP job that times out while
waiting for approval reports `never ran`: the automation never executed, so there is nothing to
debug in the playbook. Reporting that as `FAILED` sends an operator to investigate code that
never ran. [servicenow-aap.md §10 ](servicenow-aap.md#10-status-read-back-and-callback) maps
these separately, and the mapping must be preserved.

**The job timeout must exceed the approval window.** A production build that legitimately waits
a day for approval and then fails on a 12-hour job timeout has converted a pause into an
incident. This is a configuration error, and it is worth a specific assertion in the AAP
configuration review.

---

## 9. Error Messages

### 9.1 Structure

| Element | Audience | Contains |
|---|---|---|
| `code` | Machine | A stable identifier. Never localised, never reworded |
| `message` | Everyone | What happened, from a **closed template set** |
| `actionable` | Requester | What to do instead |
| `detail_source` | Operator | A JSON pointer into `context.json` |
| `retryable` | Machine | Drives the retry decision |
| `stage`, `attempt`, `run_id` | Operator | Where and when |

### 9.2 What a message must never contain

§21: "Do not expose raw secrets or sensitive infrastructure details in error messages."

| Never | Because |
|---|---|
| A credential, token or key | Obvious |
| A raw Python/traceback exception | Contains file paths, and may contain configuration values |
| A full resolved configuration | Estate topology |
| A subscription, VNet, subnet or image resource ID | Same, and it is in a widely-readable surface |
| An OU distinguished name or a domain name beyond the FQDN | Internal structure |
| An internal hostname not already in the contract | Topology |
| An absolute filesystem path outside the repository | Layout disclosure |
| A stack trace | Same as a raw exception |
| Another user's data | Privacy |

### 9.3 Construction

Requester-facing messages are **built from templates with parameter substitution**, never
composed from an exception:

```python
# Correct: a closed template, with a parameter
MESSAGES = {
    "SUBNET_IP_EXHAUSTED": (
        "Subnet {subnet_ref} has {free} free address(es); {requested} requested.",
        "Reduce count to {free}, or request a subnet range extension through "
        "the network change process (ref {change_ref}).",
    ),
    "QUOTA_EXCEEDED": (
        "The {provider} quota for {family} vCPUs in {region} is "
        "{limit}; this request needs {requested}.",
        "Submit a quota increase request to {owning_team}, then re-raise "
        "this request. No infrastructure was created.",
    ),
}

# The raw exception is logged locally, with the request id, and never rendered
LOG.error("preflight failed", extra={"request_id": rid, "stage": "validate",
                                    "exc_info": True})
return failure(code="QUOTA_EXCEEDED", **params)
```

`subnet_ref` in the message is the *symbolic reference* from the catalogue
(`snet-payments-prod-app`), not the resolved provider ID. It is meaningful to the network team
that has to act on it, and it is not a topology disclosure.

### 9.4 Examples

| Situation | Requester sees | Operator sees additionally |
|---|---|---|
| `QUOTA_EXCEEDED` | "The Azure quota for Standard_D vCPUs in westeurope is 24; this request needs 8." + "Submit a quota increase request to Cloud Platform, then re-raise this request. No infrastructure was created." | `detail_source`, `run_url`, `sba_git_sha` |
| `SUBNET_IP_EXHAUSTED` | "Subnet snet-payments-prod-app has 1 free address; 2 requested." + "Reduce count to 1, or request a subnet range extension (ref NET-CHG-8841)." | The subnet's owning team from the catalogue |
| `POLICY_VIOLATION` | "Production batches are limited to 2; 4 requested." + "Submit 2 separate requests, or request a policy exception via the platform team." | The policy file and the rule id |
| `DOMAIN_DC_UNREACHABLE` | "1 of 2 servers failed domain join: no domain controller responded." + "Verify DC reachability from snet-payments-prod-app, then re-run stage domain_join. No infrastructure will be recreated." | The hosts, the DCs tried, the AD event log reference |
| `IMAGE_EXPIRED` | "Catalog entry win-2025-enterprise expired on 2026-09-01." + "The replacement win-2025-enterprise-r2 is approved. Re-raise this request." | The catalogue entry history |
| `UNSUPPORTED_ENUM_VALUE` | "cloud 'ONPREM' is not supported. Supported: AZURE, AWS, GCP." + "Register the cloud in configuration/clouds/ before requesting it." | The catalogue version |
| `NAME_TAKEN` | "Short name pypa001 is already in use in corp.example.com." + "The naming engine has no free variant in this scope. A platform team member must allocate a code for this application." | The scope, the attempted names, the counter state |

Every `actionable` is a real action. "Contact support" is not an action, and a message that
offers one has failed its own requirement.

---

## 10. Escalation

| Condition | Route | Timing |
|---|---|---|
| `RESOLVER_ERROR`, `INTERNAL_ERROR` | Platform on-call | Immediately |
| Canary leak test failure | Security | Immediately, and the pipeline stops |
| Cross-engine parity failure | Automation team | Immediately |
| EE unavailable (blocks all prod builds) | Automation + platform on-call | Immediately |
| `STATE_STORE_UNAVAILABLE` after retries | Platform on-call | Immediately; the platform cannot guarantee idempotency |
| `IMAGE_REVOKED` | Security + image pipeline | Immediately |
| `QUOTA_EXCEEDED` in prod | Cloud platform team | Next business day; not an incident |
| Repeated `PARTIAL` (≥3 in 24 h for one app/role) | Platform team | Daily digest |
| Orphan detected by the daily report | Platform team | Daily digest |
| `DOMAIN_CREDENTIAL_INVALID` | Directory admins | Immediately; a possible credential problem, and lockout risk on the next attempt |
| `DNS_RECORD_CONFLICT` | Network + the service owner | Immediately; a live name is involved |

The two immediate-escalation rows in the middle are about the *platform's own* health rather
than a single build's, and they are separated from the per-build noise deliberately: a run-state
store outage or a broken EE affects every build at once, and it should page as an availability
incident rather than appearing as a hundred individual build failures.

---

## 11. Next

- Idempotency mechanics: [idempotency.md](idempotency.md)
- Error code registry: [api-contract.md §3.2 ](../api/api-contract.md#32-error-code-registry)
- Lifecycle failure branches: [request-lifecycle.md §5 ](request-lifecycle.md#5-failure-branches)
- Runbooks for the three terminal outcomes: [../runbooks/](../runbooks)
