# Open Questions

Status: **Phase 1 — Proposed**

Decisions that are **not** yet made. Each has a recommendation, a rationale, and the date by which
an answer is needed.

These are questions, not gaps. Where a design needed a position to proceed, a default was
adopted and marked `PROPOSED` in
[architectural-decisions.md](architecture/architectural-decisions.md); the questions here are the
ones where the default is a guess rather than a derivation.

---

## 1. Blocking — an answer is needed before Phase 2

| ID | Question | Recommendation | Rationale | Needed by |
|---|---|---|---|---|
| OQ-01 | Can the runner or AAP reach the target subnets? | Prove it in a spike before Phase 2 | If it cannot, the deployment architecture changes: a runner per network zone, or a proxy. It is the single largest schedule risk, and one network test answers it ([assumptions.md A-22](assumptions.md#7-the-assumptions-most-likely-to-be-wrong)) | Before Phase 2 |
| OQ-02 | Is the domain corporate on-premises AD or Entra ID? | Assume on-premises AD | A different answer reworks the domain-join role, `validate_os`, and the retry profile for the most common failure mode ([assumptions.md A-04](assumptions.md#1-environment-and-estate)) | Before Phase 2 |
| OQ-03 | Are subnets pre-created and IP capacity managed outside the platform? | Yes | Subnet creation is a much larger scope with a much larger blast radius ([assumptions.md A-24](assumptions.md#3-networking)) | Before Phase 2 |
| OQ-04 | Do AAP and GitHub Actions both support OIDC on the versions in use? | Yes; if not, escalate | Without it, the secret model weakens to stored client secrets throughout, which is the thing `AD-15` exists to avoid | Before Phase 2 |
| OQ-05 | Is AAP or AWX? | AAP | AWX has no approval workflow, so approval enforcement moves entirely to ServiceNow plus a manual launch. Workable, weaker ([assumptions.md A-15](assumptions.md#2-servicenow-and-aap)) | Before Phase 4 |
| OQ-06 | Do gold images exist, or is an image pipeline a prerequisite? | Treat the image pipeline as a parallel workstream | It cannot be compressed by writing more code, and Phase 4 depends on it ([assumptions.md A-07](assumptions.md#1-environment-and-estate)) | Before Phase 4 |

---

## 2. Important — an answer is needed before Phase 4

| ID | Question | Recommendation | Rationale |
|---|---|---|---|
| OQ-07 | Which Azure subscription/project/account per environment? | Separate, per environment, with no overlap | Isolation must be structural, not a convention ([assumptions.md A-01](assumptions.md#1-environment-and-estate)) |
| OQ-08 | Is `prod` on GitHub Actions, AAP, or both? | AAP as the default, GitHub as a documented manual fallback | A manual production dispatch from GitHub should be a deliberate break-glass path, not a peer ([servicenow-aap.md](architecture/servicenow-aap.md)) |
| OQ-09 | Is a ServiceNow custom role available for approval enforcement? | Yes | A group-membership check is weaker and leaves the enforcement outside the platform's audit trail ([servicenow-github-actions.md](architecture/servicenow-github-actions.md)) |
| OQ-10 | Can the platform call the CMDB directly, or must a MID Server relay? | Direct, with MID as the documented fallback | A MID Server is a supported pattern, but it adds a component that must itself be monitored ([cmdb.md](architecture/logical-architecture.md)) |
| OQ-11 | What is the expected number of builds per day? | Measure it in Phase 4 | It sizes the concurrency semaphore, the runner pool, and the batch size. Inventing a number would be a number nobody checked ([assumptions.md §8 ](assumptions.md#8-what-was-deliberately-not-assumed)) |
| OQ-12 | Is a self-hosted runner acceptable for nonprod and prod? | Yes, if the network requires it | The alternative is a proxy, which is a new component to operate ([assumptions.md A-14](assumptions.md#2-servicenow-and-aap)) |
| OQ-13 | Which AD group or OU structure is the target? | Catalogue-driven per application | It must be a catalogue value, not a hard-coded path, or every new application needs a code change |
| OQ-29 | How are callbacks authenticated — mTLS or OAuth2 client credentials? | mTLS, with OAuth2 client credentials as the documented fallback | A callback is a state-changing inbound endpoint, so an unauthenticated one is a remote-provisioning hole. mTLS needs no new token machinery ([api-contract.md §6 ](api/api-contract.md#6-callback-contract), [security-architecture.md](security/security-architecture.md)) |

---

## 3. Design — an answer is needed before the relevant phase

| ID | Question | Recommendation | Rationale |
|---|---|---|---|
| OQ-14 | Which CI/CD vendor for the platform's own pipeline? | GitHub Actions | The runtime engine is already GitHub Actions; a second CI vendor adds a tool for no gain |
| OQ-15 | Which secret store? | HashiCorp Vault, or the cloud-native stores per environment | Both are compatible with the interface. Vault centralises; the cloud-native stores avoid a dependency. Decide on operational ownership, not features |
| OQ-16 | Which monitoring and logging platform for the platform's own telemetry? | Whatever the ops team already runs | A new observability platform is not this project's job |
| OQ-17 | What is the target build duration? | 20-60 minutes, with a 10-minute pre-flight | Pre-flight is the requester's first impression; the whole build's duration is the second ([assumptions.md A-48](assumptions.md#6-process-and-people)) |
| OQ-18 | Is a second approval required for regulated workloads (PCI, SOX)? | Yes, and it is a policy floor | It belongs in `policies/prod.yml`, so it is data rather than a code branch ([configuration-resolution.md §10 ](architecture/configuration-resolution.md#10-policy-gate)) |
| OQ-19 | How long is a change freeze, and who declares it? | Per environment, in the catalogue, as a date range | A freeze is a policy input, so it should be policy data ([configuration-resolution.md](architecture/configuration-resolution.md)) |
| OQ-20 | Do build servers need a public IP for outbound only? | No, use NAT | Simplest. Revisit if an agent requires a fixed source address |
| OQ-21 | What is the retention period for run artifacts and audit logs? | Per the compliance requirement | A policy, not a design decision, but the platform must implement configurable retention |
| OQ-22 | Is there an existing golden-image pipeline to consume, or does this platform need to build images? | Consume an existing pipeline | Image building is a separate platform. The catalogue is the contract between them |
| OQ-30 | Which policy-as-code technology enforces the resolver's rules? | `ansible-lint` plus custom rules in Phase 2; revisit OPA/Conftest if rule count grows | The Phase 1 rules are a few dozen and all live in Python next to the resolver. A policy engine earns its cost at a different order of magnitude ([configuration-resolution.md §10 ](architecture/configuration-resolution.md#10-policy-gate)) |

---

## 4. Deferred — a later phase

| ID | Question | Recommendation | When |
|---|---|---|---|
| OQ-23 | Should the platform support a post-build *arbitrary* stage? | No in v1 | Post-build demand may prove a fixed stage insufficient ([roadmap.md §11 ](roadmap.md#11-explicitly-out-of-scope)) |
| OQ-24 | Should the platform ever provision Kubernetes or databases? | No | A different resource model and blast radius ([roadmap.md §11 ](roadmap.md#11-explicitly-out-of-scope)) |
| OQ-25 | Should cost rightsizing be automated? | Recommendations only, never automatic | An automatic resize of a production server is not a safe default |
| OQ-26 | Should multi-region builds be a first-class option? | Catalogue-driven already; a resilience feature is out of scope | If a resilience requirement emerges |
| OQ-27 | What is the decommission path for the legacy process? | Application by application, with a 30-day pilot | Phase 9 ([roadmap.md](roadmap.md#10-phase-9--decommission-the-legacy-process)) |
| OQ-28 | Should the platform expose a read-only API for external consumers? | Not in v1 | A consumer need would justify it; a speculative API would be a liability |

---

## 5. Questions This Design Answered Without Asking

Recorded because "why did they do it this way" is a fair question, and the answer should be
findable.

| Question | Answer | Where |
|---|---|---|
| Why not a gateway? | A state machine is a distributed system to operate. Direct callbacks and reconciliation are simpler and adequate ([AD-10](architecture/architectural-decisions.md#ad-10-no-automation-gateway-service-in-v1)) | `AD-10` |
| Why not a `CloudProvider` base class? | The dispatch is in YAML, so a class hierarchy would require the dynamic includes `AD-08` prohibits | [provider-abstraction.md §1 ](architecture/provider-abstraction.md#1-why-a-contract-not-a-base-class) |
| Why retain on failure rather than destroy? | Domain objects, DNS records, and CMDB records would be orphaned, and the diagnostic evidence destroyed | [AD-16](architecture/architectural-decisions.md#ad-16-forward-fix-over-auto-destroy) |
| Why a lock per stage per instance, not per run? | A serial batch would deadlock on a run-level lock | [idempotency.md §6.1 ](architecture/idempotency.md#61-mechanism) |
| Why is capacity not retryable? | A quota does not restore itself within a retry window, so retrying is pure delay. A *rate* limit is retryable, and the two are often confused | [failure-and-retry.md §2 ](architecture/failure-and-retry.md#2-error-taxonomy) |
| Why not retry a domain credential failure? | Retries multiply failed logons and can **lock the service account** | [failure-and-retry.md §4.2 ](architecture/failure-and-retry.md#42-not-retryable--and-why) |
| Why not auto-resolve a DNS conflict? | The record points at a different IP. Silently overwriting could take a live service offline | [failure-and-retry.md §4.2 ](architecture/failure-and-retry.md#42-not-retryable--and-why) |
| Why per-server resource groups on Azure? | It is what makes a narrower destroy identity possible. A flat group can only be destroyed all-or-nothing | [azure.md §2 ](architecture/cloud/azure.md#2-resource-group-layout) |
| Why is `sba_instance_id` a label and not only an annotation on GCP? | GCP IAM conditions can only read labels, so a label is the only way to get tag-based least privilege | [gcp.md §3.1 ](architecture/cloud/gcp.md#31-the-decision) |
| Why is a read-back needed after the GCP annotation write? | The compute API can accept a resource with a label that was silently dropped, and return 200. A missing ownership label would cause a duplicate on the next run | [gcp.md §3.2 ](architecture/cloud/gcp.md#32-why-a-read-back) |
| Why does a GCP label drift cause a reboot? | Labels can only be set at creation on GCP. A change needs a stop/start, so it is a reboot-equivalent event and is reported as one | [gcp.md §3.4 ](architecture/cloud/gcp.md#34-the-iam-consequence) |
| Why not name-scope the GCP IAM condition? | A name is derived. It does not survive a rename, a re-adoption, or drift. A tag is bound to the resource's identity | [gcp.md §8 ](architecture/cloud/gcp.md#8-per-run-least-privilege) |
| Why is `AD-18` a generated run inventory rather than a static one? | A static inventory cannot represent a server that does not exist yet | [AD-18](architecture/architectural-decisions.md#ad-18-inventories-hold-control-plane-hosts-only) |
| Why is a job timeout longer than the approval window? | Otherwise a legitimate approval pause becomes an incident, reported as a failure of code that never ran | [failure-and-retry.md §8 ](architecture/failure-and-retry.md#8-timeouts) |
| Why does the GCP doc not present "zone" as resilience? | A GCP zone is a deployment locality with no isolation guarantee. Claiming otherwise would be promising something GCP does not provide | [gcp.md §2 ](architecture/cloud/gcp.md#2-zones-are-not-zones) |
| Why a project and not a collection? | It owns playbooks, inventories, configuration, and the EE. A `galaxy.yml` would mislead anyone trying to consume it from Galaxy | [AD-13](architecture/architectural-decisions.md#ad-13-this-repo-is-an-ansible-project-not-a-collection) |

---

## 6. How to Work Through This List

1. **Before Phase 2**: OQ-01 to OQ-04. Four questions, each answerable in a single conversation.
2. **Before Phase 4**: OQ-07 to OQ-13. These shape the sandbox and the identity design.
3. **Per phase**: the relevant section of the third table.
4. **Deferred items stay deferred** until a requirement makes them concrete. A question with no
   requirement behind it is a distraction.

The order matters. OQ-01 through OQ-04 are worth asking this week, because each one can change the
architecture, and an architecture change discovered in Phase 4 costs a phase.

---

## 7. Next

- [assumptions.md](assumptions.md) — the assumptions behind the recommendations here
- [architectural-decisions.md](architecture/architectural-decisions.md) — the decisions to approve
- [roadmap.md](roadmap.md) — the phases these questions gate
