# Roadmap and Phase Exit Criteria

Status: **Phase 1 — Proposed**

The phases, what each delivers, the exit criteria, and what is deliberately not in scope.

Current status: **Phase 1 complete (documentation and structure).** Awaiting approval to begin
Phase 2.

---

## 1. Phases

```
  P1  Documentation & Structure     ████████████  COMPLETE (awaiting approval)
  P2  Resolver & Contract           ░░░░░░░░░░░░
  P3  Run State & Reporting         ░░░░░░░░░░░░
  P4  One Provider, End to End      ░░░░░░░░░░░░
  P5  OS Baseline & Domain          ░░░░░░░░░░░░
  P6  Post-Build Integration        ░░░░░░░░░░░░
  P7  Second & Third Providers      ░░░░░░░░░░░░
  P8  Production Hardening          ░░░░░░░░░░░░
  P9  Decommission Legacy            ░░░░░░░░░░░░
```

**P4 before P7 is the important ordering decision.** Getting one provider genuinely working end to
end — through a real ServiceNow request, a real engine, a real server, a real CMDB record — is
worth more than having three providers working partially. It proves the *pipeline*, and the
pipeline is what is hard. The second and third providers are then a matter of applying a contract
that is known to work.

---

## 2. Phase 1 — Documentation and Structure

### Delivered

| Deliverable | Location |
|---|---|
| Architecture decisions, conflicts, invariants, risks | [architecture/architectural-decisions.md](architecture/architectural-decisions.md) |
| Enterprise architecture: context, deployment, data, integration, security, risks | [architecture/enterprise-architecture.md](architecture/enterprise-architecture.md) |
| Logical architecture: layers, components, contracts, review violations | [architecture/logical-architecture.md](architecture/logical-architecture.md) |
| Request lifecycle: state machine, 11 stages, statuses | [architecture/request-lifecycle.md](architecture/request-lifecycle.md) |
| ServiceNow → GitHub Actions design | [architecture/servicenow-github-actions.md](architecture/servicenow-github-actions.md) |
| ServiceNow → AAP design | [architecture/servicenow-aap.md](architecture/servicenow-aap.md) |
| Configuration resolution model and precedence | [architecture/configuration-resolution.md](architecture/configuration-resolution.md) |
| Provider abstraction contract | [architecture/provider-abstraction.md](architecture/provider-abstraction.md) |
| Per-cloud notes: Azure, AWS, GCP | [architecture/cloud/](architecture/cloud) |
| Role taxonomy, DAG, standards | [architecture/role-dependency-model.md](architecture/role-dependency-model.md) |
| Execution Environment | [architecture/execution-environment.md](architecture/execution-environment.md) |
| Failure taxonomy, retry, compensation, escalation | [architecture/failure-and-retry.md](architecture/failure-and-retry.md) |
| Idempotency: `sba_instance_id`, create-or-adopt, reconciliation | [architecture/idempotency.md](architecture/idempotency.md) |
| CI/CD pipeline design | [architecture/cicd-pipeline.md](architecture/cicd-pipeline.md) |
| Repository structure | [architecture/repository-structure.md](architecture/repository-structure.md) |
| Security architecture | [security/security-architecture.md](security/security-architecture.md) |
| Secret management | [security/secret-management.md](security/secret-management.md) |
| API contract, error registry, role dependency model | [api/api-contract.md](api/api-contract.md) |
| Testing strategy | [testing/testing-strategy.md](testing/testing-strategy.md) |
| Assumptions, open questions, glossary | [assumptions.md](assumptions.md), [open-questions.md](open-questions.md), [glossary.md](glossary.md) |
| The directory skeleton | the repository itself |
| Orientation only — no implementation | `configuration/`, `roles/`, `scripts/`, `tests/`, `playbooks/`, `automation/`, `schemas/`, `.github/workflows/`, `mock/`, `execution-environment/` hold `.gitkeep` and a `README.md` each, and nothing else |

`docs/architecture/repository-structure.md` shows the *target* tree, which includes files this
phase does not create: `.github/CODEOWNERS`, `.pre-commit-config.yaml`, and the six
`schemas/*.json`. Those are Phase 2 deliverables (see below), not Phase 1 omissions.

### Exit criteria

| # | Criterion | Status |
|---|---|:--:|
| 1 | All 22 architectural decisions recorded with rationale, alternatives, and consequences | ✅ |
| 2 | All 18 design conflicts identified, with resolutions | ✅ |
| 3 | Every cross-cutting invariant stated and made checkable | ✅ |
| 4 | Both engine designs complete, including RBAC, credentials, and OIDC | ✅ |
| 5 | Configuration model with precedence, naming, images, and tags | ✅ |
| 6 | Provider contract plus per-cloud implementation notes for all three clouds | ✅ |
| 7 | Error taxonomy, retry policy, idempotency, and reconciliation | ✅ |
| 8 | Repository structure with placement rules recorded; the rules enforced in CI | ✅ rules · ⏳ enforcement |
| 9 | Security architecture and secret management | ✅ |
| 10 | API contract with JSON Schemas specified | ✅ |
| 11 | Testing strategy with layer definitions | ✅ |
| 12 | Assumptions and open questions documented | ✅ |
| 13 | No implementation code, no credentials, no cloud resources | ✅ |
| 14 | Explicit approval before Phase 2 | ⏳ **PENDING** |

Criterion 14 is the one that is not yet satisfied, and it is the reason the platform has no code
yet.

---

## 3. Phase 2 — Resolver and Contract

**Goal: everything between a request and a fully resolved configuration, with no cloud
involvement at all.**

### Deliverables

| Item | Detail |
|---|---|
| `schemas/*.json` | **Done.** Four schemas (`service-request` and `callback` dropped with the ServiceNow boundary), `additionalProperties: false` at every level, version 1.0.0 |
| `.pre-commit-config.yaml`, `.github/CODEOWNERS` | The gates that enforce the placement and security rules: `pre-commit-ansible-lint`, `yamllint`, `markdownlint`, `gitleaks`, `check-yaml`, and per-area ownership |
| `scripts/lib/sba_resolver/` | The complete resolver: loader, precedence, variables, naming, tags, images, policy, errors |
| `scripts/resolve_configuration.py` | The CLI. Reads a contract, writes `run_context.json` |
| `configuration/` | Populated: 3 clouds, 4 regions each, 3 applications, 3 server roles, 2 OS families, images, policies, routing, tags, naming |
| `tests/unit/` | 100% branch coverage on the resolver, plus property tests and golden files |
| `tests/fixtures/golden/` | The committed golden resolution files |
| `configuration/README.md` | How to add an application, a region, an image |

### Exit criteria

| # | Criterion |
|---|---|
| 1 | `resolve_configuration.py` turns a valid contract into a complete `run_context.json`, deterministically |
| 2 | 100% branch coverage on `sba_resolver`; a surviving mutation test fails the build |
| 3 | Order-independence proven: two different key orderings resolve identically |
| 4 | Purity proven: no I/O outside the configuration tree, no clock, no randomness |
| 5 | Every one of the 18 invalid-contract cases returns a specific, actionable error |
| 6 | The 200-case corpus produces no unhandled validator exception |
| 7 | Golden files regenerate with a reviewable diff on a configuration change |
| 8 | Property tests confirm no input ever produces a `short_name` > 15 or an invalid FQDN |
| 9 | A catalogue change is possible by adding one file, with no code change |
| 10 | Cross-cloud leakage is impossible: a single `apply_to` cannot affect two providers |

### Why this phase is first

It is the only phase where a mistake is cheap to make and cheap to find. Everything downstream
consumes its output, and a resolver bug becomes a wrong production server rather than a failed
test. Doing it first, exhaustively, with no cloud involved, is the cheapest place to be correct.

---

## 4. Phase 3 — Run State and Reporting

### Deliverables

| Item | Detail |
|---|---|
| `scripts/sba_state` | The run-state client: CAS, locking, append-only history, TTL |
| The state store adapter | Plus a local mock implementing real CAS semantics |
| `roles/platform/run_state` | Read/write/lock as a role |
| `roles/platform/report` | The result artifacts, and the roll-up rules |
| `tests/` | L1 state tests, L5 integration with the mock |

### Exit criteria

| # | Criterion |
|---|---|
| 1 | CAS works correctly under concurrent writers; the mock proves it |
| 2 | A lock TTL expiry is recovered safely |
| 3 | Every state transition in the [lifecycle](architecture/idempotency.md#5-the-run-state-state-machine) is reachable and tested |
| 4 | `run_result.json` and `stage_result.json` validate against their schemas |
| 5 | A partial batch rolls up to `PARTIAL` correctly |
| 6 | A crash between any two state writes leaves recoverable state |
| 7 | No secret ever appears in a state file (canary test) |

---

## 5. Phase 4 — One Provider, End to End

**Azure first.** It is the most likely primary cloud, its IAM and tag model are the best
understood, and `azure.azcollection` is the most mature of the three.

### Deliverables

| Item | Detail |
|---|---|
| `playbooks/server_build.yml` | The single entry point, stage-parameterised |
| `playbooks/stages/provision.yml` + 10 more | The stage wrappers |
| `playbooks/server_destroy.yml` | The governed teardown |
| `roles/platform/validate_request`, `policy_gate`, `image_resolver` | |
| `roles/provider/azure_vm`, `roles/image/azure_image` | The full [contract](architecture/provider-abstraction.md#2-the-role-contract) |
| `roles/dns/dns_registration` | Forward and PTR, per-host |
| `roles/cmdb/servicenow_cmdb` | The CI upsert by `sba_instance_id` |
| `.github/workflows/server-build.yml` | The GitHub Actions runtime path |
| `automation/servicenow/` | The Business Rule, REST Message, Flow |
| `automation/github/` | The adapter |
| Sandbox infrastructure | The dev resource groups, the identity, the OIDC trust policy |
| `inventories/dev/` | The control-plane inventory |

### Exit criteria

| # | Criterion |
|---|---|
| 1 | A test RITM produces a correctly configured, correctly tagged Azure VM with a DNS record and a CMDB record |
| 2 | The VM's tag set exactly matches the golden file for that provider |
| 3 | A re-run adopts and changes nothing: `changed == 0`, instance count unchanged |
| 4 | A crash after create is recovered by the next attempt's tag lookup |
| 5 | Every stage runs standalone against a completed predecessor (stage re-entry) |
| 6 | A failure at `validate` or `policy_gate` creates nothing |
| 7 | A destroy removes the VM, the DNS record, the CMDB record, and the AD object, and only the resources the run created |
| 8 | The canary leak test finds the canary in no sink |
| 9 | `sba_instance_id` is present in the cloud tag set, the DNS record set, and the CMDB record |
| 10 | An Molecule idempotence scenario passes for every role |
| 11 | The L5 playbook integration suite passes end to end |
| 12 | The prod identity cannot be reached from a `pull_request` |

### Why Azure first

Its tag model needs no workaround; its role boundary (the per-server resource group) is
expressible; its `azure_rm_*` modules are create-or-update, which aligns with create-or-adopt;
and its collection is actively maintained. GCP would have been the hardest choice for a first
provider, and AWS the easiest-looking but the one where the SSM-only bootstrap is most likely to
hit an organisation-specific constraint.

---

## 6. Phase 5 — OS Baseline and Domain

### Deliverables

| Item | Detail |
|---|---|
| `roles/os/linux_baseline` | Packages, sysctl, SSH, time sync, NTP, users, patching |
| `roles/os/windows_baseline` | Features, services, policy, Defender, RDP disabled, local administrator |
| `roles/security/cis_linux`, `cis_windows` | CIS benchmark application |
| `roles/security/security_agent`, `vulnerability_agent` | Agent install and enrolment |
| `roles/monitoring/monitoring_agent` | Monitoring |
| `roles/backup/backup_agent` | Backup |
| `roles/domain/windows_domain_join`, `linux_domain_join` | With the retry policy for AD replication |
| `roles/validate_os` | The stage assertion |
| A test AD domain | With a CA, group policies, and OU structure |

### Exit criteria

| # | Criterion |
|---|---|
| 1 | A joined Windows host passes a CIS benchmark at the catalogue's level |
| 2 | `os_config` re-run produces `changed == 0` |
| 3 | The local administrator password is rotated away from the AMI default in the same run |
| 4 | A domain join succeeds against a real domain, including replication lag |
| 5 | All four agents enrol and report |
| 6 | Agents receive configuration from the management platform, not from a bootstrap script |
| 7 | A domain credential failure does **not** retry (no lockout) |
| 8 | `validate_os` fails a deliberately non-compliant host with a specific finding |

---

## 7. Phase 6 — Post-Build Integration

### Deliverables

| Item | Detail |
|---|---|
| `automation/aap/` | Job templates, workflow templates, credential definitions, inventories |
| `.github/workflows/server-destroy.yml` | The approved teardown path |
| `.github/workflows/server-validate.yml` | The pre-flight-only path |
| `playbooks/post_build.yml` + `roles/post_build/` | A single stage re-runnable in isolation |
| `automation/aap/inventories/` | The inventory source |
| `docs/runbooks/` | The operational procedures |
| `scripts/verify_tags` | The tag-integrity auditor |

### Exit criteria

| # | Criterion |
|---|---|
| 1 | A production run launches on AAP with approval enforced before Stage 1 |
| 2 | `never ran` is distinguished from `failed` in the callback |
| 3 | The AAP job timeout exceeds the maximum approval dwell time |
| 4 | A post-build stage runs against a live server with no other stage re-running |
| 5 | A partial run is diagnosable from the artifacts alone |
| 6 | The runbooks are executable by someone who did not build the platform |
| 7 | `verify_tags` reports zero untracked resources in the sandbox |
| 8 | Both engines produce byte-identical `context.json` for the same contract |

---

## 8. Phase 7 — Second and Third Providers

### Deliverables

| Item | Detail |
|---|---|
| `roles/provider/aws_ec2`, `roles/image/aws_image` | The full contract |
| `roles/provider/gcp_compute`, `roles/image/gcp_image` | Including the labels/annotations split |
| `configuration/clouds/aws.yml`, `gcp.yml` | Capability declarations |
| `configuration/regions/` | Per-provider region files |
| `tests/` | Contract, parity, and idempotence tests per provider |

### Exit criteria

| # | Criterion |
|---|---|
| 1 | Both new providers pass the identical contract test suite |
| 2 | The parity test shows no signature drift between the three roles |
| 3 | `sba_instance_id` is in the **label** set on GCP, not only in the annotations |
| 4 | The GCP `tags_converge` read-back is proven to catch a missing label |
| 5 | A label change that would need a stop/start is correctly reported as a reboot-equivalent event |
| 6 | The same contract builds on all three clouds with only `cloud` changed |
| 7 | Per-provider immutable/mutable attributes are enforced by the respective roles |
| 8 | Each provider's OIDC trust policy passes the negative tests |

**This is a major version bump** ([cicd-pipeline.md §8 ](architecture/cicd-pipeline.md#8-release-management)).
A consumer that assumed three providers has to handle four.

---

## 9. Phase 8 — Production Hardening

### Deliverables

| Item | Detail |
|---|---|
| `AUTHZ.md` | The complete permission register, per identity, per resource, per action |
| Per-environment OIDC trust policies | With the negative tests automated |
| Per-server resource group / naming boundary | On every provider |
| Nightly reconciliation | The drift sweep, read-only |
| The daily orphan report | Paged on a non-zero `ORPHAN_UNTRACKED` |
| `CHECKLIST-per-environment.md` | A verifiable promotion checklist |
| An external penetration test | Findings remediated |
| Chaos testing | Idempotence under injected failures |
| The disaster recovery runbook | State store loss, EE loss, region loss |

### Exit criteria

| # | Criterion |
|---|---|
| 1 | `AUTHZ.md` exists and every grant in every cloud identity maps to a line in it |
| 2 | No identity holds a permission it does not need, verified by a quarterly review |
| 3 | Every OIDC negative test passes in all three environments |
| 4 | A production run cannot touch a resource with a different `sba_instance_id` |
| 5 | A production identity cannot reach dev, and a dev identity cannot reach prod |
| 6 | The chaos suite proves exactly one resource exists after every injected failure |
| 7 | Reconciliation reports zero unexplained drift over 30 days |
| 8 | The orphan report has been non-zero at least once, and the investigation worked |
| 9 | The penetration test is closed |
| 10 | A failed state store fails closed rather than proceeding without durable state |

---

## 10. Phase 9 — Decommission the Legacy Process

### Deliverables

| Item | Detail |
|---|---|
| The legacy runbook | Documented **before** the cutover |
| A pilot application | One real application on the platform |
| Parallel-run comparison | The platform's output against the legacy output, for the same application |
| The cutover | Application by application |
| The legacy retirement | Runbooks retired, ServiceNow flows disabled |

### Exit criteria

| # | Criterion |
|---|---|
| 1 | A pilot application runs in production for 30 days with no manual correction |
| 2 | The platform's output matches the legacy output on every comparable attribute |
| 3 | A requester's ticket type has changed, so nobody has to remember which system to use |
| 4 | The legacy path is disabled, not merely discouraged |
| 5 | A rollback is available and has been tested |

### Why this is last and not first

Decommissioning a working process is a change-management problem, not a technical one, and doing
it before the platform is proven would be reckless. But it is a **real** phase, and leaving it out
would leave the organisation running two systems indefinitely — which reliably means the legacy
one quietly becomes the default again, because it is the one people already know.

---

## 11. Explicitly Out of Scope

| Not doing | Why | Revisit if |
|---|---|---|
| A portal or UI | ServiceNow is the interface. A second UI fragments the experience | Requesters ask for something ServiceNow cannot express |
| Post-build arbitrary orchestration | v1 runs fixed stages. Flexible workflows reintroduce unreviewable change paths | Post-build demand proves a fixed stage insufficient |
| A gateway state machine | [AD-10](architecture/architectural-decisions.md#ad-10-no-automation-gateway-service-in-v1) | A provider needs a callback the engines cannot receive |
| Kubernetes / GKE provisioning | Different resource model, different failure model, different blast radius | A container platform is requested |
| Database provisioning | Same | Same |
| Automatic OS upgrades | A rebuild is the mechanism. Upgrading in place during a build conflates two changes | — |
| A provider plugin API | [AD-08](architecture/architectural-decisions.md#ad-08-provider-abstraction-via-a-fixed-contract--role-allow-list). A plugin is a dynamic role by another name | Never, on current evidence |
| Cost optimisation / rightsizing | A recommendation is useful; an automatic resize of a production server is not | FinOps requests recommendations |
| Multi-region failover | Out of scope for a build platform | A resilience requirement emerges |

---

## 12. Dependencies and Prerequisites

| Prerequisite | Needed by | Owner |
|---|---|---|
| ServiceNow developer access | Phase 4 | Platform team |
| A ServiceNow test instance | Phase 4 | Platform team |
| AAP (or AWX) with OIDC support | Phase 4 | Platform team |
| A GitHub org with OIDC enabled | Phase 4 | Platform team |
| Sandbox subscriptions/projects/accounts | Phase 4 | Cloud platform team |
| An AD test domain with a CA | Phase 5 | Directory team |
| An image pipeline producing gold images | Phase 5 | Image pipeline team |
| A CMDB schema with a CI class | Phase 4 | CMDB team |
| A DNS zone delegated to the platform | Phase 4 | Network team |
| A secret store | Phase 3 | Security team |
| An existing PKI / certificate service | Phase 5 | Security team |
| An enterprise monitoring platform | Phase 5 | Ops team |
| An enterprise package repository | Phase 5 | Ops team |

**None of these are technical dependencies the team can work around.** Several are organisational
and need to be requested early; the platform's schedule is dominated by waiting for cloud
sandbox access and an AD test domain, not by writing code.

---

## 13. Next

- [assumptions.md](assumptions.md) — what the design assumes
- [open-questions.md](open-questions.md) — what still needs a decision
- [architecture/architectural-decisions.md](architecture/architectural-decisions.md) — the decisions to approve
