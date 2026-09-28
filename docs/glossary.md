# Glossary

Status: **Phase 1 — Proposed**

Terms of art used across the documentation. Where a term has a precise meaning in this design
that differs from its general meaning, the difference is stated.

---

## A

**Adapter** — The thin component in front of GitHub Actions that receives ServiceNow's webhook,
validates the request, and dispatches the workflow or the AAP job. It holds no cloud credentials
and computes nothing.

**`additionalProperties: false`** — A JSON Schema keyword that rejects any property not
explicitly declared. Used at every level of every schema, so an unknown field is an error rather
than something silently ignored.

**Approval dwell time** — The time a production job spends waiting for human approval. The AAP
job timeout must exceed it, or a legitimate pause becomes a failure.

**At-least-once + idempotent** — The delivery model this platform uses, in place of exactly-once.
See [idempotency.md §3.1 ](architecture/idempotency.md#31-why-not-exactly-once).

---

## B

**Bootstrap** — Stage 2, the short-lived local administrator used before a server is joined and
managed. Rotated away in Stage 5.

**Business contract** — The engine-neutral, provider-neutral, business-only request document
([AD-02](architecture/architectural-decisions.md#ad-02-engine-neutral-run-contract-as-the-integration-seam)).
Not to be confused with the *ServiceNow payload*, which is the technical form of the same data.

---

## C

**CAS (compare-and-swap)** — A write that succeeds only if the stored version matches the expected
version. The run-state store's locking and idempotency mechanism, and deliberately not a
store-specific lock API, so the store can be S3, GCS, Azure Blob, Vault, or Postgres.

**Capacity error** — A cloud that cannot currently do the thing: quota exceeded, subnet IPs
exhausted, size unavailable in the region. **Not retryable** — none of these restore themselves
within a retry window. A *rate* limit is a different thing and **is** retryable.

**CMDB** — The ServiceNow Configuration Management Database, holding one CI record per server.

**Compensation** — Undoing a *partial* creation. Distinct from `destroy`, which is a governed
operation on a complete server. Compensation only deletes resources the run created
([idempotency.md §10 ](architecture/idempotency.md#10-compensating-actions)).

**Concurrent Request Separation** — Two live ServiceNow requests for the same scope, prevented by
the naming and concurrency policy. A second request waits or is rejected; it does not race.

**Control plane** — The machines that run the automation: the runner, AAP, and the platform's own
servers. The only hosts in a static inventory ([AD-18](architecture/architectural-decisions.md#ad-18-inventories-hold-control-plane-hosts-only)).

**Converge** — Move a resource to the desired state without creating or deleting. The
complement of create-or-adopt.

**Correlation ID** — One identifier for a whole build, spanning every stage and every attempt.
`run_id` identifies one attempt; `sba_instance_id` identifies one server.

**Create-or-adopt** — The core idempotency operation: look up by `sba_instance_id` tag, then
create if absent, adopt if present, error if ambiguous
([idempotency.md §4 ](architecture/idempotency.md#4-create-or-adopt)).

---

## D

**Data disk** — A non-OS attached volume.

**Destroy** — A governed teardown of a complete server, requiring a ServiceNow request. Never a
consequence of a failed build ([AD-16](architecture/architectural-decisions.md#ad-16-forward-fix-over-auto-destroy)).

**Drain** — Gracefully remove a server from load balancing before destroying it. Deferred: v1
does not automate it.

---

## E

**EE (Execution Environment)** — A container image containing Ansible, Python, and the pinned
collections, so the automation runs identically on GitHub Actions and AAP. Promoted by digest,
never rebuilt between nonprod and prod.

**Engine** — GitHub Actions or AAP. Exactly one is active for a given run
([AD-21](architecture/architectural-decisions.md#ad-21-single-active-engine-per-run)).

**Environment** — `dev`, `nonprod`, or `prod`. A first-class security boundary: identity,
network, policy, and image approval all differ per environment.

**`expires_at`** — The date after which a catalogue image is no longer approved. Checked at
resolution, so an expired image fails before any resource exists.

**External dependency error** — A failure in a dependency the platform does not control (the state
store, the EE, GitHub, the identity provider). Retryable, then escalated as an availability
incident.

---

## F

**FQDN** — Fully qualified domain name, e.g. `pypa001.payments.corp.example.com`. Separate from
`short_name` ([AD-06](architecture/architectural-decisions.md#ad-06-two-name-model-short-netbios-name--long-fqdn)).

**Forward fix** — Repairing a partially built server in place rather than destroying and
rebuilding it.

---

## G

**Gateway** — A stateful intermediate service. **Not in v1**
([AD-10](architecture/architectural-decisions.md#ad-10-no-automation-gateway-service-in-v1)).

**Golden file** — A committed expected-output file compared against actual output. The
resolution golden files double as a review artefact: a configuration change shows its own diff.

---

## H

**Hard dependency** — A stage that cannot run without an earlier stage having succeeded. Contrast
*stage re-entry*.

**Hybrid inventory** — Static control-plane hosts plus a run-generated group holding the servers
being built, merged at run time.

---

## I

**Idempotent** — Safe to run twice with the same result. The platform's `G-3` and `G-4`
guarantees.

**`I-1`..`I-8`** — The cross-cutting architecture invariants
([architectural-decisions.md §3 ](architecture/architectural-decisions.md#3-cross-cutting-invariants)),
each enforced by a CI gate.

**Immutable / mutable attribute** — Whether a resource attribute can be changed after creation.
Immutable on Azure: subscription, region, resource group, subnet, image. Mutable: size, tags.
The split is per provider, and it is what `IMMUTABLE_MISMATCH` enforces.

---

## J

**Job (AAP)** — One execution of a job template. Its `never ran` status is distinct from `failed`.

**Jump host / bastion** — A host used for administrative access. Not used by the build.

---

## K

**Knowledge Base article** — A ServiceNow KB article, in the self-service catalogue, explaining
how to raise a request. Not a technical component.

---

## L

**Labels vs annotations (GCP)** — Labels are ≤63 characters, lowercase, and the only metadata
readable by IAM conditions. Annotations are unbounded. The platform writes both, and the label is
mandatory because tag-based IAM depends on it
([AD-11](architecture/architectural-decisions.md#ad-11-gcp-labels-for-indexable-subset-annotations-for-full-metadata)).

**Least privilege, per run** — The production identity being scoped to a single
`sba_instance_id`, via an Azure Policy tag condition, an AWS `aws:ResourceTag` condition, or a
GCP IAM condition on `resource.labels`.

**Lock TTL** — How long a stage lock is held before it may be taken over. 15 minutes, refreshed
every 5. A crashed holder must not block a run forever.

---

## M

**Managed identity** — An Azure MI, an AWS instance profile, a GCP service account. Attached to a
server only when the role needs cloud access.

**MID Server** — A ServiceNow instance that relays CMDB traffic from inside the network.

---

## N

**Naming engine** — The component generating `short_name` and `fqdn` deterministically
([AD-06](architecture/architectural-decisions.md#ad-06-two-name-model-short-netbios-name--long-fqdn)).

**NetBIOS name** — The 15-character Windows computer name. The reason `short_name` exists.

---

## O

**Orphan** — A resource carrying no `sba_instance_id`, or one whose run state is gone. Detected by
a daily tag-based sweep. `ORPHAN_UNTRACKED` is paged, because it means the ownership model has
been violated.

---

## P

**`PD-1`..`PD-n`** — The platform invariants, in the run state.

**Policy floor** — A per-environment minimum: batch size, disk encryption, image approval,
required tags.

**Post-build stage** — A stage that can be run against a live server, in isolation, without
re-running anything before it. The operational equivalent of `AD-01`.

**Provider capability declaration** — A role's `vars/main.yml` describing regions, zones, metadata
limits, and immutable attributes. The TagMapper reads it, so provider differences are data
([provider-abstraction.md §6 ](architecture/provider-abstraction.md#6-capability-declaration)).

---

## Q

**QUnX** — The naming pattern: `<app_code><role><env_digit><index>`, e.g. `pypa001`.

---

## R

**Reconciliation** — A scheduled, **read-only** verification that the estate matches the catalogue.
Distinct from a re-run, which is an action taken in response to a known failure.

**`R-01`..`R-12`** — The architecture risk register
([architectural-decisions.md §9 ](architecture/enterprise-architecture.md#9-architecture-risk-register)).

**Resolver** — The pure function producing the single effective configuration for a run
([AD-22](architecture/architectural-decisions.md#ad-22-resolver-is-read-only-and-side-effect-free)).
Pure, deterministic, clock-free, no cloud calls.

**Retention** — Keeping infrastructure after a failure so it can be fixed forward, rather than
destroying it.

**`revoked_at`** — Emergency withdrawal of a catalogue image, checked immediately at pre-flight,
distinct from the scheduled `expires_at`.

**Role contract** — The six task groups every provider role implements
([provider-abstraction.md §2 ](architecture/provider-abstraction.md#2-the-role-contract)).

**Run context** — The resolver's output: the single effective configuration for one run.

**`run_id`** — One execution attempt. A retry gets a new one.

**Run state** — The authoritative execution record in the object store
([AD-04](architecture/architectural-decisions.md#ad-04-run-state-store-is-the-execution-source-of-truth)).

**Runtime pipeline** — The workflows that execute server builds. Distinct from the CI/CD pipeline
that builds the platform's own code
([cicd-pipeline.md §1 ](architecture/cicd-pipeline.md#1-two-pipelines-one-repository)).

---

## S

**Scope** — The uniqueness boundary for a server name: `<region>:<app_code>:<dns_scope>`. The
counter lives per scope.

**Semaphore** — The distributed per-`sba_instance_id` lock enforcing that one engine acts on a
server at a time.

**Serial** — Building a batch one host at a time. A deliberate choice, so a DNS or AD problem
affects one server at a time rather than all of them.

**Stage re-entry** — Running one stage against a completed predecessor, using durable state,
without re-running anything before it. The reason there is only one entry playbook
([AD-01](architecture/architectural-decisions.md#ad-01-single-entry-playbooks--staged-re-entry)).

**Tag / label** — Cloud resource metadata carrying `sba_instance_id` and the canonical key set.

**TagMapper** — The component mapping canonical metadata to each provider's format, applying the
capability declaration's limits, and recording every transformation.

**Transitive dependency** — A role that includes another role, creating a DAG. Restricted to
`platform/` roles.

**Triggering user** — The ServiceNow user who raised the request. **Not** in the business
contract ([AD-19](architecture/architectural-decisions.md#ad-19-derived-fields-are-resolved-server-side-by-servicenow)).

---

## T

**Tag-with-create** — The rule that `sba_instance_id` is applied in the same API call that creates
the resource. Not before (impossible), not after (a crash loses ownership)
([idempotency.md §4.3 ](architecture/idempotency.md#43-the-tag-with-create-rule)).

**Transient error** — A temporary environmental condition: a timeout, a throttle, a port not yet
open. **Retryable** with backoff.

**Triggering phase** — The ServiceNow process (record or item) that generates the request.

---

## U

**Unknown state** — A recorded outcome whose truth is not known, e.g. a cloud call that timed out
after possibly succeeding. Resolved by a read, never by a write
([idempotency.md §5 ](architecture/idempotency.md#5-the-run-state-state-machine)).

---

## V

**Validation failure** — The request or configuration is not usable. Nothing was created. Not
retryable: the same input produces the same failure.

**Versioning** — `schema_version` in the contract, and the semver of the platform. Additive within
a major ([AD-20](architecture/architectural-decisions.md#ad-20-additive-schema-versioning-only)).

---

## W

**Workflow (GitHub Actions)** — A YAML file in `.github/workflows/`, the canonical location
([AD-12](architecture/architectural-decisions.md#ad-12-canonical-workflows-live-in-githubworkflows)).

---

## Z

**Zone** — Azure: an availability zone, a physical failure domain. AWS: an availability zone.
GCP: a **deployment locality with no isolation guarantee**. The platform does not present a GCP
zone as a resilience control ([gcp.md §2 ](architecture/cloud/gcp.md#2-zones-are-not-zones)).

---

## Next

- [architecture/](architecture) — the designs these terms come from
- [api/api-contract.md](api/api-contract.md) — the wire format
