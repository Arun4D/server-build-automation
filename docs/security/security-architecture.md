# Security Architecture

Status: **Phase 1 — Proposed**

Trust boundaries, identity model, RBAC, input validation, audit, supply chain, and the
compliance controls that make the platform defensible in an enterprise setting.

Decisions: [AD-15](../architecture/architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs),
[AD-08](../architecture/architectural-decisions.md#ad-08-provider-abstraction-via-a-fixed-contract--role-allow-list),
[AD-02](../architecture/architectural-decisions.md#ad-02-engine-neutral-run-contract-as-the-integration-seam),
[AD-17](../architecture/architectural-decisions.md#ad-17-approval-authority-stays-in-servicenow),
[AD-19](../architecture/architectural-decisions.md#ad-19-derived-fields-are-resolved-server-side-by-servicenow),
[AD-20](../architecture/architectural-decisions.md#ad-20-additive-schema-versioning-only).

Related: [secret-management.md](secret-management.md).

---

## 1. Security Principles

Applied in this order when they conflict.

| # | Principle | Consequence |
|---|---|---|
| S-1 | **The requester is untrusted, always** | Even a legitimate requester cannot supply a technical parameter. The schema rejects it ([I-1](../architecture/architectural-decisions.md#3-cross-cutting-invariants)) |
| S-2 | **Structure over policy** | A guarantee that holds because of a type or a schema is stronger than one held by a runtime check. "The AI can only generate a structured request" is structural, not procedural |
| S-3 | **No standing privilege** | Every identity is short-lived and job-scoped. No service account holds a permission it uses only occasionally |
| S-4 | **No secret ever crosses an input boundary** | Not in a contract, an extra-var, a workflow input, a survey, a tag, or the run-state store ([AD-15](../architecture/architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs)) |
| S-5 | **Least privilege per environment and per stage** | Separate identities for dev/nonprod/prod, and separate read-only identities for pre-flight |
| S-6 | **Every action attributable** | `request_id` + `run_id` + `sba_instance_id` on every log line, every tag, every CMDB record |
| S-7 | **The platform is not the approver** | Business approval lives in ServiceNow; the platform enforces technical and organisational policy only ([AD-17](../architecture/architectural-decisions.md#ad-17-approval-authority-stays-in-servicenow)) |
| S-8 | **Deny by default, fail closed** | An unresolvable configuration, a missing policy, a failed pre-flight ⇒ no infrastructure. Never a partial or best-effort create |
| S-9 | **Immutable audit records** | `request.json` and `fingerprint.json` are written once and never modified |
| S-10 | **Reduce blast radius** | Self-hosted runners are ephemeral and per-environment; a compromised build cannot persist |

---

## 2. Trust Boundaries

```
  ==========================================================================================
  T0  UNTRUSTED
      ServiceNow catalog variables · user input · chatbot output · AI agent output
      ── controls: closed enums, additionalProperties:false, count bounds, no free text ──
  ============================== boundary: contract schema validation =====================
  ==========================================================================================
  T1  PLATFORM CONTROL PLANE
      Adapters · resolver · policy gate · stage machine · run-state store
      Identity: OIDC / managed identity, job-scoped, short TTL
      Holds NO secrets. Makes NO cloud mutation.
  ============================== boundary: scoped per-stage cloud identity =================
  ==========================================================================================
  T2  CLOUD CONTROL PLANE
      cloud/*_vm · image/*_image · pre-flight
      Identity: per-environment, per-cloud, per-stage least privilege
      Writes: tag-complete, idempotent, attributable
  ============================== boundary: WinRM/SSH, ephemeral, per-host ==================
  ==========================================================================================
  T3  BUILD TARGET
      OS baseline · domain join · agents · DNS
      Identity: domain join account (non-interactively-logonable), agent enroll tokens
      Agent installers come from an internal allow-listed source, never the internet
  ============================== boundary: scoped integration identity =====================
  ==========================================================================================
  T4  MANAGEMENT PLATFORMS
      ServiceNow CMDB · monitoring · backup · vulnerability scanning · DNS
      Identity: one per platform, per direction. No shared superuser.
  ==========================================================================================
```

### 2.1 What crosses each boundary, and how it is checked

| Boundary | Crossing data | Check on the far side |
|---|---|---|
| T0→T1 | Run contract (9 fields) | JSON Schema, closed enums, `count` bounds, `request_id` format, `change_reference` presence for governed envs. Rejected data never reaches a runner |
| T1→T2 | Resolved configuration + a scoped cloud identity | Policy gate already passed; `sba_cloud_role` asserted to be a member of the closed map; `sba_instance_id` present in every tag set |
| T2→T3 | WinRM/SSH session, ephemeral credential | Host is one the platform just created, matched by `sba_instance_id`; no arbitrary host targeting. This is why the generated inventory is an **exact set** ([AD-18](../architecture/architectural-decisions.md#ad-18-inventories-hold-control-plane-hosts-only)) |
| T3→T4 | Enrollment tokens, join credentials | One platform at a time; tokens scoped to the target; consumed once where the platform supports it |
| Any→ServiceNow | Callback | Signature verified; idempotency key applied; unsigned or mismatched ⇒ rejected **and logged as a security event** |

**The T2→T3 boundary is the most dangerous one, and it is worth being explicit about why.**
A build that can connect to any host can modify any host. The control is not authentication —
it is *target selection*: the inventory is generated from `context.json` and contains only the
`sba_instance_id` values this run allocated. A requester cannot widen it, because they cannot
express a host in the contract at all ([S-1](#1-security-principles)). An operator editing
`context.json` is an act with the platform's own credentials and is visible in the audit trail.

---

## 3. Identity Model

Nine identities. Each is separate, each is used for one purpose
([AD-15](../architecture/architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs)).

| Identity | Type | Lifetime | Grants | Authenticates by |
|---|---|---|---|---|
| `svc-sba-servicenow` | ServiceNow → platform | Long (rotated) | **Launch the dispatch entry point, nothing else** | OAuth2 client credentials |
| `svc-sba-github` | GHA → cloud | Per job (OIDC, ≤1 h) | Cloud actions for one env, in one repo, on allow-listed refs | OIDC federation |
| `svc-sba-aap` | AAP → cloud | Per job or per instance | Cloud actions for one env | OIDC / instance profile / credential |
| `svc-sba-{cloud}-{env}-provision` | Platform → cloud (create) | Per run | Create/read/delete **only** the specific resource types in the catalogue | OIDC / managed identity |
| `svc-sba-{cloud}-{env}-read` | Platform → cloud (pre-flight) | Per run | **Read + quota only.** No create, no delete | OIDC / managed identity |
| `svc-sba-state` | Platform → run-state store | Per run | Read/write `sba-runs/{env}/**` only | Managed identity / workload identity |
| `svc-sba-domainjoin` | Platform → AD | Long (rotated) | Create/move computer objects in configured OUs only. **Not** a Domain Admin | Credential store |
| `svc-sba-dns-{env}` | Platform → DNS | Long (rotated) | Create/update/delete in configured zones only | Credential store |
| `svc-sba-servicenow-cmdb` | Platform → ServiceNow | Long (rotated) | Write to `cmdb_ci*` and relationships. **Read-only** elsewhere | OAuth2 client credentials |
| `svc-sba-cicd` | CI → repositories/artifacts | Long (rotated) | Push to this repo; push/pull to the EE registry | GitHub App / deploy key |

### 3.1 The provision/read split is the important one

Pre-flight (§20) makes read-only cloud calls and runs *before* any provisioning
([AD-22](../architecture/architectural-decisions.md#ad-22-resolver-is-read-only-and-side-effect-free)). If
pre-flight shares an identity with provisioning, then a bug in the pre-flight code path — or
in anything that can influence which code runs — inherits the ability to create and delete
infrastructure.

Splitting them means:

- The component that processes untrusted-adjacent input (the request, the catalogue) has
  **no** write capability in the cloud.
- The component that writes is never reached until validation has passed, so it only ever
  sees a configuration that has already been policy-checked.
- A compromised resolver or catalogue is a read-only information-disclosure event, not a
  destructive one. **This bounds the blast radius of a supply-chain attack on the
  configuration** — which is a far more likely attack than one on the playbooks.

### 3.2 Cloud permission shape (example, Azure)

Never a role at subscription scope. Always resource scope, never a wildcard on a resource
*type* the platform does not use.

```
  Read-only (pre-flight):
    Microsoft.Compute/subscriptions/{sub}/providers/Microsoft.Compute/locations/read
    Microsoft.Compute/locations/usages/read
    Microsoft.Compute/images/read
    Microsoft.Compute/galleries/read
    Microsoft.Network/virtualNetworks/read
    Microsoft.Network/virtualNetworks/subnets/read
    Microsoft.Resources/subscriptions/read

  Provision:
    the above, plus
    Microsoft.Compute/virtualMachines/write            scoped to {resourceGroup}
    Microsoft.Compute/virtualMachines/delete          scoped to {resourceGroup}
    Microsoft.Compute/networkInterfaces/write          scoped to {resourceGroup}
    Microsoft.Compute/disks/write                     scoped to {resourceGroup}
    Microsoft.Network/networkSecurityGroups/write      scoped to {resourceGroup}

  Explicitly NOT granted:
    Microsoft.Authorization/*/write                   (no RBAC self-escalation)
    Microsoft.Compute/virtualMachineScaleSets/write
    Microsoft.Network/virtualNetworks/write            (no network creation)
    Microsoft.Resources/deployments/write              (no arbitrary ARM)
    Any subscription outside the catalogue's allow-list
```

Three absences are deliberate. No RBAC write means a compromised build cannot grant itself
more permissions. No network write means it cannot create a route or a VNet to exfiltrate
through. No ARM deployment permission means it cannot use an arbitrary template to do
something the playbook did not intend.

The same shape applies on AWS (scoped IAM policy with `Resource` ARNs per resource type, no
`iam:*`, no `ec2:RunInstances` on unapproved AMIs) and GCP (roles at the resource or project
level, no `resourcemanager.projects.setIamPolicy`, no `serviceusage.services.enable`).

### 3.3 Domain join account

Not a Domain Admin, and specifically:

| Property | Requirement | Why |
|---|---|---|
| Scope | Create/move computer objects in the configured OUs only | A compromised build must not be able to create a privileged account anywhere in the domain |
| Group membership | Delegated OU permission via a group, not direct ACL on the domain | Reviewable and revocable in one place |
| Logon rights | **"Deny log on locally"**, "Deny log on through Remote Desktop Services", "Deny access to this computer from the network" on all servers | A domain join account that can log on to servers is a lateral-movement path. This is the most commonly missed control in domain-join automation |
| Password | Managed by the directory, rotated on a schedule and on any suspected exposure | Long-lived static passwords are the standard weakness here |
| SPN / delegation | None | The account must not be delegation-trusted; it only needs to create computer objects |
| Auditing | Computer-object creation events are forwarded to the SIEM | So AD-side compromise is detectable independently of the platform's own logs |

`no_log: true` on every task that consumes it, without exception
([servicenow-aap.md §7.1 ](../architecture/servicenow-aap.md#71-credential-hygiene-rules)).

---

## 4. Input Validation

The security control that §2 of the bootstrap asks for, expressed as enforcement.

### 4.1 Validation happens four times, each for a different reason

| Point | What it catches | Why here specifically |
|---|---|---|
| **ServiceNow catalog** | Invalid choices at data entry | Cheapest possible rejection; the requester sees it while still on the form |
| **Adapter** | Malformed or extra fields from any caller, including a future chatbot | The adapter is the trust boundary; a caller that bypasses the catalog must not be able to smuggle fields |
| **Resolver** | Enum membership, type, bounds, precedence conflicts, policy | The authoritative check; the first one that can produce an actionable message |
| **Workflow/job guard** | Anything that changed after dispatch | Defence in depth against a mutated catalogue or a tampered run-state object |

Four checks look redundant. They are not: each is the last line of defence before a different
component would act on the data, and the cost of each is milliseconds.

### 4.2 The schema is the control

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["schema_version", "request_id", "application", "environment",
               "cloud", "region", "server_role", "os", "count"],
  "properties": {
    "cloud":        { "enum": ["AZURE", "AWS", "GCP"] },
    "environment":  { "enum": ["DEV", "NONPROD", "PROD"] },
    "os":           { "enum": ["WINDOWS", "LINUX"] },
    "count":        { "type": "integer", "minimum": 1, "maximum": 16 },
    "request_id":   { "type": "string", "pattern": "^RITM[0-9]{10}$" },
    "vm_size":      false
  }
}
```

`"vm_size": false` is JSON Schema's way of forbidding a property explicitly, and it is used for
each of the technical fields the bootstrap forbids. It is not only restrictive; it is
**self-documenting**: a reviewer reading the schema sees what is deliberately excluded, and a
requester who tries gets an error naming the forbidden field. An allow-list alone would produce
a generic "unexpected property" message.

### 4.3 Injection and traversal resistance

| Attack | Control |
|---|---|
| Role name injection (`cloud_provider: "../../roles/evil"`) | Closed enum map; the value reaching a role name is never free text ([AD-08](../architecture/architectural-decisions.md#ad-08-provider-abstraction-via-a-fixed-contract--role-allow-list)) |
| Jinja/template injection via a catalogue value | No configuration value is ever evaluated as a template. `{placeholder}` substitution is a plain string format with a fixed key set; unknown keys are an error, not an expression |
| YAML tag exploitation in a catalogue file | `yaml.safe_load` only |
| Path traversal via an application name | Application names are validated against `^[A-Z][A-Z0-9_]{1,31}$` **before** any path is constructed. A path is built only from a validated identifier, never concatenated from raw input |
| Command injection via a hostname or tag value | No shell. Hostnames are validated against a strict regex; `shell`/`command` is not used where a module exists (§31) |
| SSRF via a requester-supplied URL | No URL is ever supplied by a requester. Endpoints come from the catalogue, and the catalogue is a reviewed repository artifact |
| Command injection via the callback | The callback is a structured JSON POST to a fixed ServiceNow host from the adapter. No content is ever interpolated into a command or a URL path from request data |

### 4.4 Resource exhaustion by a legitimate user

A valid request must not be able to exhaust the platform or the cloud.

| Control | Value | Effect |
|---|---|---|
| `count` schema maximum | 16 | Bounded in the schema, before anything else |
| Per-role batch maximum in configuration | Varies (e.g. `database: 4` in prod) | Policy floor, environment-specific |
| `max_batch_serial` policy | 1 in prod | A `count: 16` prod request is legal but runs one at a time, so it takes hours rather than minutes. Slow is the correct response to a large prod request |
| Environment concurrency semaphore | Configurable (e.g. 5 concurrent runs per env) | Prevents a burst of RITMs from exhausting quota or runner capacity |
| Non-production cost cap and auto-expiry | Configurable | Sandbox environments expire and are reported, not left to accumulate |
| Rate limit on the dispatch endpoint | Configurable per caller | Protects the adapter and the engine APIs |

The philosophy: a large legitimate request is *slow*, not *denied*. Denying it teaches the
requester to work around the platform; making it slow is both safe and self-limiting.

---

## 5. Data Protection

| Class | Content | At rest | In transit | Access | Logged? |
|---|---|---|---|---|---|
| **A — Request** | Contract, enum values. No PII ([AD-19](../architecture/architectural-decisions.md#ad-19-derived-fields-are-resolved-server-side-by-servicenow)) | Run-state store (encrypted) | TLS 1.2+ | Platform operators | **Yes, in full.** Safe by construction |
| **B — Resolved configuration** | Subscriptions, VNets, subnet CIDRs, image pins, OU paths, DNS names | Run-state store (encrypted, CMK) | TLS 1.2+ | Platform operators | **Summary only** + `resolved_config_hash`. Never in full |
| **C — Credentials** | Tokens, passwords, keys, connection strings | Credential store / cloud identity platform | TLS 1.2+ | Never readable by a job user | **Never.** `no_log` + no value in any input |
| **D — Build telemetry** | Facts, task results, timings, image version, SHA, compliance output | Run-state store + log store | TLS 1.2+ | Platform operators, auditors | **Yes**, redacted |
| **E — Guest state** | Domain policy, local accounts, agent config, firewall rules | On the target | WinRM/SSH over TLS | Target admins | Summary only |

Class B is the one that is routinely mishandled. A resolved configuration is enough to
reconstruct the estate topology, so it is treated as sensitive even though it holds no
credential. Two rules follow: the full document goes to the run-state store and not to stdout,
and ServiceNow receives a summary ([request-lifecycle.md §7.1 ](../architecture/request-lifecycle.md#71-why-the-ritm-never-contains-the-technical-result-in-full)).
This is also why **no cloud ID is ever hard-coded in the repository** ([I-8](../architecture/architectural-decisions.md#3-cross-cutting-invariants)) —
otherwise anyone with read access to the source could learn the estate layout without any
access to the platform at all.

---

## 6. Logging and Audit

### 6.1 Never logged

`password`, `token`, `secret`, `private key`, `connection string`, `client_secret`,
`certificate body`, and the full resolved configuration.

**Primary mechanism: the value never enters a loggable position.** By
[AD-15](../architecture/architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs) no secret is an input, so
there is nothing to mask. `no_log: true` is **defence in depth**, not the primary control —
which is the correct order, because masking-based approaches fail the first time a value is
rendered somewhere unexpected.

### 6.2 Log redaction, in layers

| Layer | Mechanism |
|---|---|
| Ansible | `no_log: true` on every credential-consuming task; a CI lint rule makes its absence a failure |
| Callback | A restricted callback configuration; `log_path` off by default so a local filesystem does not accumulate a credential-bearing copy |
| GitHub Actions | `::add-mask::` for anything derived from a masked secret; the input allow-list means there is nothing secret to begin with |
| AAP | `no_log` plus AAP's own masking plus the credential store's redaction in the job detail view |
| Shell | `set -o pipefail`; no `set -x`; no `echo $VAR` |
| SIEM | Ingest-side redaction patterns as a final net, with an alert on any match — an alert is the mechanism that turns "we have a redaction rule" into "the rule works" |

The alert-on-match is the important part. A redaction rule that silently matches is
indistinguishable from one that is not running.

### 6.3 Audit records

Immutable, and answerable without reconstructing logs
([enterprise-architecture.md §7.3 ](../architecture/enterprise-architecture.md#73-compliance-and-audit)).

| Record | Content | Immutability |
|---|---|---|
| `request.json` | The contract as received, plus receipt metadata | Written once; never modified. Changing it is a new `run_id` with a new fingerprint |
| `fingerprint.json` | `sha256(canonical(contract) + catalog_version)` | Written once |
| `context.json` | Resolved configuration, allocations, `git_sha`, `ee_digest` | Written once, then appended to (additive) |
| `result.<stage>.json` | Per-stage, per-host outcome with error code, timings, attempt number | Append-only across attempts |
| Cloud activity logs | The provider's own record of every API call | Provider-controlled; the independent record |
| AAP event stream | Every template update, credential use, user authentication | AAP-controlled; the independent record of *who did what* |
| Cloud OIDC federation logs | Every short-lived token issued, and the claim that authorised it | Cloud-controlled; ties a mutation to a specific workflow run |
| AD event log | Computer-object creation and modification | AD-controlled |
| ServiceNow `sys_history` | Every RITM/CMDB field change with the user | ServiceNow-controlled |

The last five are the reason the audit story is credible: five records maintained by five
independent systems. A platform that only trusted its own logs would have a weak audit story,
because an attacker with write access to the run-state store could also rewrite the story.

### 6.4 The audit questions, and where each is answered

| Question | Answered by |
|---|---|
| Which change authorised this? | `request.json.change_reference` → ServiceNow CHG record with approver and timestamp |
| Who requested it? | `request.json` correlation → ServiceNow RITM `opened_by` (read on demand, not propagated — [AD-19](../architecture/architectural-decisions.md#ad-19-derived-fields-are-resolved-server-side-by-servicenow)) |
| Which code built it? | Cloud tag `GitSha` + `EeDigest`; `context.json.code`; AAP event stream (which job template, which project sync) |
| Which image, which version? | Cloud tag `ImageCatalogId` + `ImageVersion`; `context.json.image` (the pin) |
| Which policy was applied? | `context.json.policy_evaluation` — every rule evaluated, with violations and advisories |
| What changed on the host? | Stages 2-6 results, plus the guest's own configuration-management record |
| What did the cloud actually do? | Provider activity log — the only record that cannot be written by the platform |
| Who has accessed the run's data? | Run-state store access logs; AAP event stream |
| Was the run tampered with? | Fingerprint verification; `request.json` immutability; the state store's versioned-object history |

---

## 7. Supply Chain Security

§16. Applied to what this repository actually contains, with
[C-18](../architecture/architectural-decisions.md#2-requirement-conflict-register) resolved honestly.

### 7.1 Checks, and what each is actually protecting against

| Tool | Protects against | Blocking? |
|---|---|---|
| `yamllint` | Malformed configuration; unreviewable formatting drift | yes |
| `ansible-lint` | Correctness and maintainability defects; unsafe constructs | yes |
| `ansible.builtin.*` FQCN enforcement | Silent behaviour change when a short name resolves to a different collection | yes |
| `ansible-playbook --syntax-check` | Content that cannot run at all | yes |
| `gitleaks` | Committed credentials, in history as well as in the tree | yes |
| `trufflehog` (optional) | High-confidence secrets with verification | yes |
| `bandit` | Python defects in `scripts/` (the resolver and the state client) | yes |
| `semgrep` | Ansible-specific and generic injection patterns | yes |
| `shellcheck` via `ansible-lint` | Shell defects in the few places shell is unavoidable | yes |
| `pip-audit` / `safety` | Known CVEs in resolver and state-client dependencies | yes |
| `ansible-galaxy` / EE drift check | An EE that no longer matches the declared pinned requirements | yes |
| `checkov` / `trivy` IaC | Only if this repo emitted IaC. It does not, so this is **conditional** ([C-18](../architecture/architectural-decisions.md#2-requirement-conflict-register)) | n/a here |
| `dependency-review` | New dependencies with known vulnerabilities in a PR | yes |
| `actionlint` | Workflow syntax and expression errors | yes |
| Custom: action SHA pinning | A mutable action tag being repointed at malicious code | yes |
| Custom: permission allow-list | A workflow escalating `permissions:` | yes |
| Custom: hard-coded ID gate | A cloud/subscription/subnet/image/OU ID committed to source ([I-8](../architecture/architectural-decisions.md#3-cross-cutting-invariants)) | yes |
| Custom: no secrets in inputs | A credential entering a workflow input or `env` ([AD-15](../architecture/architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs)) | yes |
| Custom: cloud module confinement | A provider module outside `roles/cloud`/`roles/image` ([R-08](../architecture/enterprise-architecture.md#9-architecture-risk-register)) | yes |
| `pre-commit` | All of the above, locally, before commit | advisory |

The six custom checks are the ones specific to this project's design. Off-the-shelf tooling
would not catch a subnet ID in a YAML file, a credential in a workflow input, or a provider
module in a stage playbook — and those are the failures most specific to *this* platform.

### 7.2 Branch and review protection

```
  main          protected.  PR required.  >=2 approvals.  CODEOWNERS enforced.
                All mandatory checks must pass.  No bypass by admins except
                via a logged break-glass.  Signed commits required.
                Linear history or squash-merge only.

  feature/*     PR to main.  Same checks.  May not be dispatched (no workflow on
                the branch) [AD-12](../architectural-decisions.md#ad-12-canonical-workflows-live-in-githubworkflows)

  release/*     PR to main.  Same checks.  Tagged on merge; the tag is what
                nonprod and prod run.

  tag v*        Immutable.  Signed.  Referenced by prod AAP project and by the
                OIDC trust policy.
```

CODEOWNERS separates the review surface, because a configuration change and a playbook change
have different risk and different reviewers:

| Path | Required reviewers |
|---|---|
| `roles/provider/**`, `roles/image/**` | Cloud platform team |
| `configuration/policies/**` | Security + platform leadership |
| `configuration/images/**` | Image pipeline owners + security |
| `playbooks/**`, `roles/platform/**` | Automation team |
| `schemas/**` | Automation + any consumer team (a schema change is a contract change) |
| `automation/aap/**` | Automation + AAP admins |
| `.github/workflows/**` | Automation + security |
| `execution-environment/**` | Automation + security |

A `schemas/` change requiring a consumer review is a small thing that prevents the most
expensive kind of regression: a silently incompatible contract change consumed by the chatbot
or a future API.

### 7.3 Third-party content

| Content | Control |
|---|---|
| Collections | Pinned to exact versions in `requirements.yml`; resolved transitively and committed; the EE builds only from the pinned set |
| Python packages | Pinned with hashes in `requirements.txt` |
| GitHub Actions | Referenced by **commit SHA**, never by tag or branch. A tag on `actions/checkout` can be moved |
| Runner images | Digest-pinned; a runner image is treated as production software |
| EE base image | Digest-pinned in `execution-environment.yml` |
| Container images built by this pipeline | Scanned before promotion; a critical finding blocks the promotion gate |
| OS images (build targets) | Only from the approved catalogue ([AD-07](../architecture/architectural-decisions.md#ad-07-image-catalogue-with-pinning-and-expiry)); an arbitrary image ID from a requester is a supply-chain hole and is structurally impossible |

The last row is a security control expressed as an architecture property. §8 says "never allow
a normal requester to provide an arbitrary image ID for production" — in this design they
cannot provide *any* image ID, because the contract has no such field.

---

## 8. Network and Host Security

### 8.1 Platform network posture

| Component | Ingress | Egress | Notes |
|---|---|---|---|
| ServiceNow | From the corporate network | To the engine API, and to the state store via a private path | |
| Adapter / trigger | From ServiceNow only | To the engine API, cloud APIs, state store, ServiceNow callback | No public listener |
| GitHub Actions runner (self-hosted) | **None** | Agent connection to GitHub (or ARC), cloud APIs, state store, target management ports | Outbound-only. A build host with no ingress cannot be reached by a build |
| AAP instance | From the corporate network | To GitHub, cloud APIs, state store, targets | |
| Run-state store | **Private endpoint only** | None | No public egress, no public access ([AD-04](../architecture/architectural-decisions.md#ad-04-run-state-store-is-the-execution-source-of-truth)) |
| Build target (ephemeral) | WinRM/SSH from the runner subnet, management ports only | To AD, DNS, monitoring, backup, vulnerability, internal package sources | No inbound from the internet |

The private-endpoint-only rule for the state store is a direct consequence of it holding Class B
data ([§5 ](#5-data-protection)). A publicly-reachable run-state store would be a topology
disclosure for the whole estate, readable by anyone who could guess an object key.

### 8.2 Target host hardening

Applied by `os/<family>_baseline` and by the image baseline. The role does not *design* the
hardening; it verifies the image meets it and remediates drift.

| Control | Linux | Windows |
|---|---|---|
| Remote management | SSH only, key-based only, root login disabled, password auth disabled | WinRM over TLS, NTLM-in-TLS or Kerberos only, plaintext disabled |
| Firewall | Default-deny inbound; management ports restricted to the runner subnet | Windows Firewall default-deny inbound; management ports restricted to the runner subnet |
| Patching | Image baseline + role-applied updates | Image baseline + role-applied updates; pending-reboot handling |
| Local accounts | Named admin pattern from the resolved configuration; no shared accounts | Named admin pattern; local admin disabled where domain policy allows |
| Privilege | Passwordless sudo with a restricted command set; auditd rules | UAC enforced; admin accounts not used for daily work |
| Time sync | NTP/chrony from the approved internal source | Windows Time from the domain hierarchy |
| Logging | rsyslog/journald forwarding to the SIEM | Event log forwarding to the SIEM |
| Compliance | CIS benchmark applied and reported | CIS benchmark applied and reported |
| Egress | Restricted to required management endpoints; no general internet | Same; agent traffic is allow-listed by destination |

The egress restriction is worth calling out: without it, a compromised or misconfigured build
target has unrestricted internet access, which turns any in-guest vulnerability into an
exfiltration path. Restricting egress to the specific management endpoints is a
control-plane-adjacent decision, so it is configured per environment and per role rather than
hard-coded.

---

## 9. Vulnerability and Compliance Posture

| Concern | Control |
|---|---|
| CIS benchmarks | Applied by `security/cis_{linux,windows}`; drift reported; deviations recorded with a justification and an expiry in the resolved configuration |
| Vulnerability scanning | Agent installed in Stage 5; **first scan is verified to have completed** before the stage reports success. A stage that installs a scanner and does not confirm it runs is not a control |
| Image compliance | `security_attestation` in the catalogue; optional pre-flight check `COMPLIANCE_MISSING` |
| Evidence | Every build produces compliance output retained with the run, so compliance is evidenced per server rather than sampled |
| Patch currency | Image age and patch level are recorded per build; a catalogue entry past its patch SLA produces an advisory |
| Agent health | Agent service running, heartbeat received, policy applied, and — where the platform supports it — a test alert |
| Data classification | `DataClassification` in the tags, and the catalogue's `min_image_classification` floor enforced at selection |
| Segregation of duties | Technical policy (platform) is separate from business approval (ServiceNow) ([AD-17](../architecture/architectural-decisions.md#ad-17-approval-authority-stays-in-servicenow)) |

The "verify the agent actually works" control generalises: **installing a security control is not
the same as having one.** A monitoring agent that installed but cannot reach its collector, or a
scanner that never ran its first scan, produces a build that reports success and an asset that
is effectively unmanaged. Every agent stage therefore ends with a *functional* verification, not
a presence check. This is the difference between a compliance-mapped platform and a
compliance-claimed one.

---

## 10. Security Testing

| Test | Method | Frequency |
|---|---|---|
| Secret scanning | `gitleaks` over the tree and full history | Every push; every PR |
| SAST | `semgrep` (Ansible + Python rulesets), `bandit` on `scripts/` | Every PR |
| Dependency scanning | `pip-audit`, `ansible-galaxy` version check, `dependency-review` | Every PR |
| IaC / EE scanning | `triapi-contract.md §8; `checkov` if IaC is present | On EE build; on PR if IaC is present |
| Workflow analysis | `actionlint`, SHA-pinning check, permission allow-list check | Every PR |
| Ansible static analysis | `ansible-lint` incl. FQCN, `no_log`, and idempotency rules | Every PR |
| Custom architecture gates | Hard-coded ID gate, cloud-module confinement, no-secrets-in-inputs, input allow-list | Every PR |
| Contract tests | Schema negative cases; closed-enum rejection; forbidden-field rejection | Every PR |
| Resolver purity | `socket` monkeypatched to raise; no network import | Every PR |
| OIDC negative tests | Wrong repo, wrong environment, wrong ref, wrong audience, wrong subject ⇒ denied | Integration, per environment |
| Privilege tests | Each identity asserted to hold *only* its intended permissions; write denied for the read-only identity; a create attempted outside the resource scope is denied | Integration, per cloud |
| Target isolation | Build a server in sandbox A; assert a run for sandbox B cannot target it | Integration |
| Secret leak test | Inject a canary credential in a test credential store; assert it appears in no log, artifact, run-state object, or RITM field | Integration, per engine |
| Callback security | Unsigned, mis-signed, replayed, and out-of-order callbacks all rejected; a replayed callback is a no-op | Integration |
| Dependency integrity | EE digest in `context.json` matches the digest in the job; `requirements.yml` matches the EE contents | Integration |
| Runner hygiene | Ephemeral runner recycled after a job; no credential or artifact on disk; no standing cloud role | Integration, per job |
| Pen test | External, before production go-live | Once, and annually |

The **canary secret** test is the most valuable of these and the least commonly done. It answers
the question that `no_log` alone cannot: does a credential leak anywhere in practice? A
distinguishing canary value is placed in a test credential, a full build is run, and every
sink — logs, artifacts, run-state objects, the RITM, the callback payload, the CMDB record — is
searched. It is the only test that verifies the whole leak path rather than one mechanism.

---

## 11. Security Requirements Traceability

| § | Requirement | Implementation | Section |
|---|---|---|---|
| 15 | No secrets in Git | Zero secrets committed; `gitleaks` blocking; no Vault in git ([AD-15](secret-management.md#6-ansible-vault-policy)) | [secret-management.md](secret-management.md) |
| 15 | OIDC / managed identity / workload identity preferred | Nine identities, none a superuser; OIDC on both engines | [§3 ](#3-identity-model) |
| 15 | Separate identities per platform | Nine identities, one per purpose | [§3 ](#3-identity-model) |
| 15 | `no_log` where necessary | Everywhere credentials are consumed, plus a lint rule | [§6.1 ](#61-never-logged) |
| 15 | Never log password/token/secret/key | Structural (never an input) + defence in depth | [§6.1 ](#61-never-logged) |
| 2 | Do not let users supply technical parameters | Closed schema with explicitly forbidden properties | [§4.2 ](#42-the-schema-is-the-control) |
| 8 | Never allow a requester to supply an image ID | No image field exists in the contract | [§7.3 ](#73-third-party-content) |
| 16 | pre-commit, ansible-lint, yamllint, gitleaks, semgrep, bandit, shellcheck | All present and blocking; `checkov`/`trivy` conditional | [§7.1 ](#71-checks-and-what-each-is-actually-protecting-against) |
| 16 | SAST, secret scanning, dependency scanning, IaC scanning, linting, YAML validation | Six CI workflow categories | [cicd-pipeline.md §4 ](../architecture/cicd-pipeline.md#4-mandatory-checks) |
| 16 | No deployment from a branch that failed checks | Branch protection; required status checks; no admin bypass except logged break-glass | [§7.2 ](#72-branch-and-review-protection) |
| 21 | Do not expose secrets in error messages | Closed message templates; raw exceptions to the platform log only | [configuration-resolution.md §11 ](../architecture/configuration-resolution.md#11-failure-model) |
| 25 | Policy as code; reject before infrastructure creation | Policy gate + pre-flight, both before any mutation | [configuration-resolution.md §10 ](../architecture/configuration-resolution.md#10-policy-gate) |
| 29 | AI must not execute arbitrary Ansible | The contract has no such field; the AI produces a document, nothing more | [api-contract.md §8 ](../api/api-contract.md#8-ai-and-chatbot-consumers) |

---

## 12. Open Security Questions

Raised with full detail in [open-questions.md](../open-questions.md).

| ID | Question | Impact if unanswered |
|---|---|---|
| OQ-06 | Which compliance frameworks must be evidenced, and to what retention? | Determines the evidence model and the `retention_days` in the run-state store |
| OQ-07 | Is the platform itself in scope for the enterprise monitoring/SIEM baseline, and does it need a hardening standard? | Determines the runner and controller hardening requirements |
| OQ-08 | Data residency: may a `PROD` run-state object exist outside the region of the server it describes? | Determines whether the state store is per-region or per-environment, and it is a significant architectural input |
| OQ-09 | Is mTLS required for the engine↔ServiceNow callback, or is OAuth2 client credentials sufficient? | Determines the callback ingress design and whether a MID Server is required |
| OQ-10 | What is the required CMDB CI retention, and must the run-state store retain beyond the CMDB lifecycle? | Determines `retention_days` and the archival design |

---

## 13. Next

- Credential patterns per engine, rotation, Vault policy: [secret-management.md](secret-management.md)
- Callback security and authentication: [api-contract.md §6 ](../api/api-contract.md#6-callback-contract)
- Supply chain checks in the pipeline: [cicd-pipeline.md §4 ](../architecture/cicd-pipeline.md#4-mandatory-checks)
- Role-level `no_log` and credential reference rules: [role-dependency-model.md §7 ](../architecture/role-dependency-model.md#7-credential-and-logging-rules)
