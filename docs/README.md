# Documentation Index

Status: **Phase 1 — Proposed**

Every document in this repository, in the order a reader should approach them.

---

## Start Here

If you have **five minutes**, read these three:

| Document | What you get |
|---|---|
| [architecture/architectural-decisions.md](architecture/architectural-decisions.md) | The 22 decisions, the 18 conflicts they resolve, the invariants, the risks |
| [architecture/enterprise-architecture.md](architecture/enterprise-architecture.md) | What the system is, who it serves, what it touches |
| [roadmap.md](roadmap.md) | The phases, and what Phase 1 delivered |

If you are **reviewing the design**, read [open-questions.md](open-questions.md) and
[assumptions.md](assumptions.md) first. Those two are where the design is most likely to be
wrong, and both are short.

---

## Architecture

| Document | Contents |
|---|---|
| [architectural-decisions.md](architecture/architectural-decisions.md) | `AD-01`..`AD-22`, conflicts `C-01`..`C-18`, invariants `I-1`..`I-8`, risks `R-01`..`R-12` |
| [enterprise-architecture.md](architecture/enterprise-architecture.md) | Context, deployment, data, integration, security views; the risk register |
| [logical-architecture.md](architecture/logical-architecture.md) | Layers, components, ownership, contracts, and the review violations to check for |
| [request-lifecycle.md](architecture/request-lifecycle.md) | The state machine, the 11 stages, statuses, retries, reconciliation, cancellation |
| [configuration-resolution.md](architecture/configuration-resolution.md) | Precedence, variables, naming, images, tags, policy, pre-flight |
| [provider-abstraction.md](architecture/provider-abstraction.md) | The six task groups, the four operations, capabilities, the provider checklist |
| [cloud/azure.md](architecture/cloud/azure.md) | Azure resources, resource group layout, identity, stage notes, error mapping |
| [cloud/aws.md](architecture/cloud/aws.md) | AWS resources, placement, IAM conditions, SSM-only bootstrap, error mapping |
| [cloud/gcp.md](architecture/cloud/gcp.md) | GCP resources, **zones are not zones**, labels vs annotations, IAM conditions |
| [role-dependency-model.md](architecture/role-dependency-model.md) | Role taxonomy, the DAG, role standards, what a role may not do |
| [execution-environment.md](architecture/execution-environment.md) | The EE, dependency pinning, promotion, runner hardening |
| [servicenow-github-actions.md](architecture/servicenow-github-actions.md) | The GitHub Actions path: adapter, workflow, OIDC, status, callback |
| [servicenow-aap.md](architecture/servicenow-aap.md) | The AAP path: projects, job templates, credentials, RBAC, approval |
| [failure-and-retry.md](architecture/failure-and-retry.md) | Error taxonomy, retryable vs not, two retry layers, compensation, messages, escalation |
| [idempotency.md](architecture/idempotency.md) | `sba_instance_id`, create-or-adopt, the run-state machine, locking, reconciliation |
| [cicd-pipeline.md](architecture/cicd-pipeline.md) | The platform's own pipeline: stages, gates, promotion, rollback |
| [repository-structure.md](architecture/repository-structure.md) | The target layout, placement rules, `ansible.cfg`, requirements, `.gitignore` |

---

## API and Contracts

| Document | Contents |
|---|---|
| [api/api-contract.md](api/api-contract.md) | The business request, run context, run result, stage result, the callback, the error registry, ServiceNow mappings |

---

## Security

| Document | Contents |
|---|---|
| [security/security-architecture.md](security/security-architecture.md) | Trust boundaries, identities, the permission shape, validation, audit, supply chain |
| [security/secret-management.md](security/secret-management.md) | OIDC, the credential store, the credential set, rotation, the emergency procedure |

---

## Testing and Operations

| Document | Contents |
|---|---|
| [testing/testing-strategy.md](testing/testing-strategy.md) | L1-L8, the pure-core rule, mocks, chaos, parity, canary, coverage, fixtures |
| [runbooks/](runbooks) | Operational procedures. Populated in Phase 6 |

---

## Project

| Document | Contents |
|---|---|
| [roadmap.md](roadmap.md) | Phases P1-P9, deliverables, exit criteria, dependencies, out of scope |
| [assumptions.md](assumptions.md) | `A-01`..`A-48`, what breaks if each is wrong, the ten most likely to be wrong |
| [open-questions.md](open-questions.md) | `OQ-01`..`OQ-28`, with recommendations and deadlines |
| [glossary.md](glossary.md) | Terms of art |
| [../PROJECT_BOOTSTRAP.md](../PROJECT_BOOTSTRAP.md) | The original brief |

---

## Reading Paths

**A requester** wants to know what will be built and when.
[glossary](glossary.md) → [request-lifecycle](architecture/request-lifecycle.md) →
[configuration-resolution §6 ](architecture/configuration-resolution.md#6-naming-engine) →
[roadmap §2 ](roadmap.md#2-phase-1--documentation-and-structure)

**A reviewer of the design.**
[architectural-decisions](architecture/architectural-decisions.md) →
[assumptions](assumptions.md) → [open-questions](open-questions.md) →
[enterprise-architecture](architecture/enterprise-architecture.md) →
[logical-architecture](architecture/logical-architecture.md)

**An implementer.**
[repository-structure](architecture/repository-structure.md) →
[api-contract](api/api-contract.md) →
[configuration-resolution](architecture/configuration-resolution.md) →
[idempotency](architecture/idempotency.md) →
[provider-abstraction](architecture/provider-abstraction.md) →
[cloud/](architecture/cloud) → [testing-strategy](testing/testing-strategy.md)

**A security reviewer.**
[security-architecture](security/security-architecture.md) →
[secret-management](security/secret-management.md) →
[cloud/gcp.md §7 -8](architecture/cloud/gcp.md#7-identity-and-authentication) →
[cloud/aws.md §7 ](architecture/cloud/aws.md#7-per-run-least-privilege) →
[azure.md §7 ](architecture/cloud/azure.md#7-per-run-least-privilege) →
[assumptions §4 ](assumptions.md#4-security-and-compliance)

**An operator.**
[request-lifecycle §5 ](architecture/request-lifecycle.md#5-failure-branches) →
[failure-and-retry §10 ](architecture/failure-and-retry.md#10-escalation) →
[idempotency §9 ](architecture/idempotency.md#9-reconciliation) →
[runbooks/](runbooks)

---

## Conventions

| Convention | Meaning |
|---|---|
| `AD-nn` | An architectural decision |
| `C-nn` | A design conflict and its resolution |
| `I-n` | A cross-cutting invariant, enforced by a CI gate |
| `R-nn` | A risk in the register |
| `A-nn` | An assumption |
| `OQ-nn` | An open question |
| `PD-n` | A platform invariant in the run state |
| Status: `PROPOSED` | Not yet approved. **Every document in Phase 1 is `PROPOSED`** |
| RFC 2119 | `MUST` / `MUST NOT` / `SHOULD` / `SHOULD NOT` / `MAY` |

**Linking.** A relative link to a heading uses the GitHub anchor form
(`[text](file.md#heading-text)`). A link to a not-yet-created document is listed in
[open-questions.md](open-questions.md) rather than left dangling silently.

---

## Status

Phase 1 is complete: documentation and structure. No implementation code exists. The next step is
approval, and then [Phase 2](roadmap.md#3-phase-2--resolver-and-contract).

---

## Next

- [../README.md](../README.md) — the repository entry point
- [architectural-decisions.md](architecture/architectural-decisions.md) — what to approve
