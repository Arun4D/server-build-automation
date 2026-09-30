# Logical Architecture

Status: **Phase 1 — Proposed**

Companion to [enterprise-architecture.md](enterprise-architecture.md). That document answers
*where things sit*; this one answers *what each component is responsible for, what it consumes,
what it produces, and what it must never do*.

Decision references (`AD-nn`) resolve to
[architectural-decisions.md](architectural-decisions.md).

---

## 1. Layer Model

Ten layers, downward-only dependencies ([enterprise-architecture.md §3 ](enterprise-architecture.md#3-container-view-c4--logical-layers)).

```
  L9  CONSUMER CHANNELS     ServiceNow · GitHub Actions · AAP · (future) Chatbot/AI/API
  L8  ADAPTER LAYER         Engine adapters            — dispatch, poll, callback
  L7  CONTRACT & STATE      Run contract · Run-state store
  L6  POLICY & RESOLUTION   Resolver · Naming · Image · Policy gate · Pre-flight
  L5  LIFECYCLE             Stage machine
  L4  PROVIDER              cloud/*_vm · image/*_image · TagMapper
  L3  OS & POST-BUILD       os/*_baseline · domain · monitoring · security · backup · dns · cmdb
  L2  EXECUTION ENVIRONMENT EE image · runner
  L1  EXTERNAL PLATFORMS    Azure · AWS · GCP · AD · DNS · CMDB · Image repos
```

Each layer has exactly one **owner of truth**. Duplicate ownership is the failure mode that
produces "which record is right?" incidents, so the table below is normative.

| Layer | Owner of truth for | Never owns |
|---|---|---|
| L9 | Business intent, approval state, user-facing workflow | Technical configuration |
| L8 | Engine run handles (`run_id`, workflow run URL, job id) | Business logic of any kind |
| L7 | Execution state: contract, resolved config, stage results | Business approval state |
| L6 | The mapping business intent → technical parameters | Runtime state (persisted by L7) |
| L5 | Stage sequencing and control flow | The parameters themselves |
| L4 | Cloud resource lifecycle | The decision *whether* to create |
| L3 | Guest OS configuration state | Cloud resource lifecycle |
| L2 | The toolchain version | Platform behaviour |
| L1 | Actual resource state | Everything above |

---

## 2. Component Catalogue

### 2.1 L9 — Consumer Channels

| Component | Responsibility | Consumes | Produces | Must never |
|---|---|---|---|---|
| **ServiceNow Flow Designer action** | Build the run contract from RITM context; call an engine; poll status; apply results to the RITM; branch to "Manual Attention" | RITM/CHG/CMDB fields | Run contract, RITM updates | Resolve technical parameters; hold a cloud or domain credential; implement retry policy for cloud operations |
| **ServiceNow Catalog** | Constrain user input to valid choices; enforce `count` bounds; derive `request_id`, `change_reference` | User input | Variable set | Accept free-text for `cloud`/`region`/`os` (`[AD-19]`) |
| **ServiceNow reconciliation job** | Periodically reconcile non-terminal RITMs against the run-state store; heal stuck requests | RITM state, run-state store | RITM corrections | Be the primary status path ([enterprise-architecture.md §6 ](enterprise-architecture.md#6-integration-view)) |
| **GitHub Actions** | Execute a run contract against a pinned commit in a chosen environment | Run contract, GitHub Secrets (OIDC trust only) | Workflow run, artifacts | Contain business logic; accept secrets as inputs ([AD-15]) |
| **AAP** | Execute a run contract against a pinned commit in an EE, with credential store, RBAC, approval nodes | Run contract, AAP Credentials | Job/unified-job, results | Duplicate orchestration content ([AD-01]); expose credentials to requesters |
| **Future Chatbot / AI Agent** | Produce a **run contract** and nothing else | User intent | Run contract JSON | Execute Ansible, call cloud APIs, or supply infrastructure parameters ([AD-29](../../PROJECT_BOOTSTRAP.md)) |

### 2.2 L8 — Adapter Layer

Two adapters, deliberately near-identical in shape, deliberately trivial in content.

| Component | Responsibility | Consumes | Produces | Must never |
|---|---|---|---|---|
| **GHA adapter** (`workflow_dispatch` / `repository_dispatch`) | Authenticate, map contract → typed workflow inputs, dispatch, record the run URL, poll to terminal, emit callback | Run contract | `run_id`, workflow run URL, status | Contain a stage list, a retry loop with business meaning, or a parameter default |
| **AAP adapter** (`POST /api/controller/jobs/.../launch/`) | Authenticate, select project/EE/job template, pass opaque `run_context_id`, record the job URL, poll, emit callback | Run contract | `run_id`, job URL, status | Duplicate the GHA adapter's logic in a divergent form; pass technical params as a survey |

**Why they are so thin.** The entire reason both engines can be supported without
duplication ([AD-01], [AD-21]) is that the adapter's only job is *transport*. If an adapter
ever needs to know what "stage 4" is, the two paths have begun to fork. The review checklist
for any adapter change is literally: *"does this line contain the name of a stage?"* — if yes,
it belongs in `server_build.yml`.

**Adapter responsibilities in full** (all four, identical for both engines):

1. **Authenticate** to the target engine using a per-environment seidempotency.md §7. **Validate** the contract against the schema before dispatch (defence in depth — L6 will
   validate again, but a bad contract should never reach a runner).
3. **Dispatch** with a **pinned `ref`**, never a branch name (pinned SHA or a release tag).
4. **Record** `run_id`, engine, run URL and start time into the run-state store before
   returning success to ServiceNow.

Point 4 ordering matters: if dispatch succeeds but the write fails, ServiceNow retries, the
adapter sees an existing `run_id` for this `(request_id, fingerprint)` and returns the
existing handle instead of dispatching again. That is the idempotent path
([idempotency.md §7 ](idempotency.md#7-per-stage-idempotency-contract)).

### 2.3 L7 — Contract & State

| Component | Responsibility | Key properties |
|---|---|---|
| **Run contract** | The only input surface. 9 business fields, `additionalProperties: false`, semver-versioned | Total, closed, non-spoofable, non-secret, safe to log in full ([AD-02], [AD-19], [AD-20]) |
| **`request.json`** | The contract exactly as received, plus receipt metadata | Written once, never mutated. Immutable audit record |
| **`fingerprint.json`** | `sha256(canonical(request) + catalog_version)` | The duplicate-detection key. Detects "same request" vs "changed request" |
| **`context.json`** | Resolved configuration + allocations: names, ids, image pin, `git_sha`, `ee_digest` | The reproducibility record. Never printed in full ([enterprise-architecture.md §5 ](enterprise-architecture.md#5-data-view)) |
| **`inventory.json`** | Generated static inventory for exactly this run's targets | Derived from `sba_instance_id` set — an exact set, not a tag filter ([AD-18]) |
| **`result.<stage>.json`** | Per-stage structured result: per-host status, error code, timings | Written before exit; drives the exit code ([AD-14], I-6) |
| **`run_result.json`** | Rollup across stages and hosts → terminal status | The single document ServiceNow ultimately reads |
| **`lock.json`** | Environment concurrency semaphore | CAS-based; no separate lock service ([AD-04](architectural-decisions.md#ad-04-run-state-store-is-the-execution-source-of-truth)) |

### 2.4 L6 — Policy & Resolution

| Component | Responsibility | Pure? | Failure mode |
|---|---|---|---|
| **Resolver** (`sba_resolver`) | `resolve(request, catalog, as_of)` → resolved configuration + provenance + diagnostics | **Yes** ([AD-22](architectural-decisions.md#ad-22-resolver-is-read-only-and-side-effect-free)) | `RESOLUTION_CONFLICT` / `NO_APPROVED_CONFIGURATION` — never a partial result |
| **Merge engine** | The 9-level precedence hierarchy with conflict detection and provenance | Yes | `PRECEDENCE_CONFLICT` when two sources set the same key at the same level with different values |
| **Naming engine** | Allocate `short_name` (≤15) and `fqdn`; reserve sequence atomically | Yes (allocation is a CAS in L7) | `NAME_COLLISION`, `NAME_UNRESOLVABLE` ([AD-06](architectural-decisions.md#ad-06-two-name-model-short-netbios-name--long-fqdn)) |
| **Image resolver** | Abstract catalogue entry → concrete pinned provider image reference; enforce approval + expiry | Yes | `IMAGE_NOT_APPROVED`, `IMAGE_EXPIRED`, `IMAGE_UNRESOLVABLE` ([AD-07](architectural-decisions.md#ad-07-image-catalogue-with-pinning-and-expiry)) |
| **TagMapper** | Business metadata → provider-shaped tags/labels/annotations | Yes | `TAG_MAPPING_INCOMPLETE` — blocks the run (I-3) ([AD-11](architectural-decisions.md#ad-11-gcp-labels-for-indexable-subset-annotations-for-full-metadata)) |
| **Policy gate** | Evaluate §25 policy: approved clouds/regions/OS/images/sizes, PROD change requirement, naming, tags, network | Yes (on resolved config) | `POLICY_VIOLATION` with the specific rule id — requester-actionable |
| **Pre-flight** (`stage: validate`) | Live checks: quota, region availability, image existence, network reachability, subnet free IPs, short-name domain uniqueness, optional approval re-verification | No — read-only cloud calls | `QUOTA_EXCEEDED`, `IMAGE_NOT_FOUND`, `SUBNET_IP_EXHAUSTED`, `NAME_TAKEN` ([failure-and-retry.md §4 ](failure-and-retry.md#4-retry-classification)) |

**Resolver purity is not pedantry.** It means (a) the entire resolution surface is unit-testable
without a cloud account, (b) the lowest-privilege component never handles a cloud token, and
(c) a resolution can be reproduced from a request months later for an audit. Pre-flight exists
precisely *because* the resolver cannot do these checks — and the split is drawn on the
credential boundary, not on convenience.

### 2.5 L5 — Lifecycle

| Component | Responsibility | Notes |
|---|---|---|
| **Stage machine** | Execute the 8 stages in order; enforce entry conditions; route failures; aggregate status | One implementation, invoked with a stage or stage list ([AD-01](architectural-decisions.md#ad-01-single-entry-playbooks--staged-re-entry)) |
| **Stage wrapper** | Load `context.json`, run the stage's roles, write `result.<stage>.json`, release resources, set exit code | Mandatory; not optional per-stage boilerplate (I-6) |
| **Batch controller** | `serial` sizing, per-host isolation, per-host result aggregation | Failure of host 2 does not abort host 3; aggregate becomes `PARTIAL` |
| **Failure router** | Classify the error; decide retry / re-run / retain / destroy; set terminal status | See [failure-and-retry.md](failure-and-retry.md) |
| **Reporter** | Build `run_result.json` and a human-readable build report (summary, not full `context.json`) | The only component permitted to serialise results for humans |

### 2.6 L4 — Provider Abstraction

| Component | Responsibility | Provider-specific? |
|---|---|---|
| `provider/azure_vm` | Create/get/validate/destroy/tag an Azure VM, NIC, NSG association, availability set/zones | Yes |
| `provider/aws_ec2` | Create/get/validate/destroy/tag an EC2 instance, ENI, SG association, placement | Yes |
| `provider/gcp_compute` | Create/get/validate/destroy/label a Compute Engine instance, NIC, firewall association | Yes |
| `image/azure_image` | Resolve a catalogue entry to a Shared Image Version reference | Yes |
| `image/aws_image` | Resolve a catalogue entry to an AMI id (pinned, or tag query recorded) | Yes |
| `image/gcp_image` | Resolve a catalogue entry to a GCP image reference | Yes |
| `TagMapper` | Emit provider-shaped metadata from business metadata | Data-driven per provider |
| **Provider dispatch** | Choose the role from a **closed enum**; never interpolate a role name from input | No |

The dispatch is a closed map, not a pattern
([AD-08](architectural-decisions.md#ad-08-provider-abstraction-via-a-fixed-contract--role-allow-list)):

```
azure -> azure_vm / azure_image
aws   -> aws_ec2 / aws_image
gcp   -> gcp_compute / gcp_image
```

Any other value is a **resolver bug** and the policy gate fails the run before dispatch. A
`cloud_provider` that arrives as free text from anywhere — a requester, a chatbot, a future API
consumer, a compromised ServiceNow field — cannot select a role.

### 2.7 L3 — OS & Post-Build

| Component | Responsibility | Windows | Linux |
|---|---|---|---|
| `os/windows_baseline` | WinRM hardening, patching, features, roles, time sync, WinRM config, baseline compliance | yes | — |
| `os/linux_baseline` | SSH hardening, patching, packages, sysctl, SELinux/AppArmor, time sync, sudo, auditd | — | yes |
| `domain/windows_domain_join` | AD join, OU placement, GPO link, reboot sequencing, orphan cleanup on re-run | yes | — |
| `domain/linux_domain_join` | realm/AD join, SSSD, OU placement, idempotent re-join | — | yes |
| `monitoring/monitoring_agent` | Install + configure + verify agent, register with the monitoring platform | yes | yes |
| `security/security_agent` | EDR/agent install, policy, connectivity verification | yes | yes |
| `security/vulnerability_agent` | Scanner install, scheduled scan, first-scan verification | yes | yes |
| `security/cis_linux` / `cis_windows` | CIS benchmark remediation, drift report | — | yes / yes |
| `backup/backup_agent` | Agent install, policy attach, first-backup verification | yes | yes |
| `dns/dns_registration` | A/CNAME/SRV/PTR records, TTL, idempotent upsert, registration order | yes | yes |
| `cmdb/servicenow_cmdb` | Upsert CI + CI relationship by `sba_instance_id`; set ownership, application, support group | yes | yes |

**OS-family divergence is handled by role selection, not playbook duplication.** One entry
playbook, one stage, `sba_os_family` selects the baseline role. The genuinely
Windows-specific mechanics — WinRM, reboot sequencing, `samAccountName`, pending-reboot
detection, GPO refresh, `Invoke-Command` vs `ansible.builtin.win_*` — live *inside* the Windows
roles and nowhere else. The orchestration never branches on OS family; it delegates.

### 2.8 L2 — Execution Environment

| Component | Responsibility | Notes |
|---|---|---|
| **EE image** | Immutable, digest-pinned bundle: `ansible-core`, collections, Python deps, OS deps, cloud SDKs, WinRM/SSH clients | [execution-environment.md](execution-environment.md) |
| **Runner** | Execute the workflow job in the EE; hold the job-scoped cloud identity; discard after use | Ephemeral, per-environment, hardened |
| **Registry** | Versioned EE storage (GHCR) with promotion dev→nonprod→prod | Digest, not tag, is what production references |

### 2.9 L1 — External Platforms

| Platform | Consumed for | Never used for |
|---|---|---|
| Azure / AWS / GCP | VM/instance lifecycle, image lookup, network facts, quota, tags | Landing-zone creation (out of scope) |
| AD / Entra ID | Domain join, OU placement, GPO, short-name uniqueness | Approvals |
| DNS | Record registration, TTL, zone alignment | Zone creation |
| Monitoring / Backup / Security platforms | Agent install, policy, enrollment, verification | Agent source distribution from the internet |
| Image repositories | Approved image resolution | Image **creation** ([AD-07](architectural-decisions.md#ad-07-image-catalogue-with-pinning-and-expiry)) |
| ServiceNow CMDB | Registration and update by `sba_instance_id` | Business approval (stays in the Flow, [AD-17](architectural-decisions.md#ad-17-approval-authority-stays-in-servicenow)) |
| GitHub | Source control, CI/CD, OIDC trust, EE registry | Storing secrets |

---

## 3. Responsibility Matrix

`●` owns · `▲` participates · `—` no involvement

| Concern | ServiceNow | Adapter | State store | Resolver | Stage machine | Provider role | OS/Post-build | EE/Runner | Cloud |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| Business intent capture | ● | ▲ | ▲ | ▲ | — | — | — | — | — |
| Approval | ● | — | — | ▲ | — | — | — | — | — |
| Contract validation | ▲ | ▲ | — | ● | — | — | — | — | — |
| Configuration resolution | — | — | ▲ | ● | ▲ | — | — | — | — |
| Policy evaluation | — | — | ▲ | ● | ▲ | — | — | — | — |
| Quota / existence pre-flight | — | — | ▲ | ▲ | ● | ▲ | — | — | ▲ |
| Name allocation | — | — | ● | ● | ▲ | — | — | — | ▲ |
| Image pinning | — | — | ● | ● | ▲ | ▲ | — | — | ▲ |
| Stage sequencing | — | ▲ | ▲ | — | ● | — | — | — | — |
| Cloud resource lifecycle | — | — | ▲ | — | ▲ | ● | — | — | ▲ |
| Tag application | — | — | ▲ | ▲ | ▲ | ● | — | — | ▲ |
| Guest OS configuration | — | — | ▲ | — | ▲ | — | ● | ▲ | — |
| Domain join | ▲ | — | ▲ | ▲ | ▲ | — | ● | ▲ | ▲ |
| DNS registration | ▲ | — | ▲ | ▲ | ▲ | — | ● | — | ▲ |
| CMDB registration | ▲ | — | ▲ | ▲ | ▲ | — | ● | ▲ | — |
| Result persistence | ▲ | ▲ | ● | — | ● | ▲ | ▲ | ▲ | — |
| Status read-back | ● | ● | ▲ | — | — | — | — | — | — |
| Credential custody | ● (SN→engine only) | ▲ | **—** | **—** | **—** | ▲ (uses) | ▲ (uses) | ▲ (holds job identity) | ▲ (trusts) |
| Audit record | ● | ▲ | ● | ▲ | ● | ▲ | ▲ | ▲ | ▲ |
| Cost attribution | ▲ | — | ▲ | ▲ | ▲ | ● | — | ▲ | ● |

Two rows carry the most architectural weight:

**Credentials** — the state store and the resolver are the only components that must *never*
hold a credential. The resolver is pure ([AD-22](architectural-decisions.md#ad-22-resolver-is-read-only-and-side-effect-free)),
so it cannot; the state store must therefore be architected so that reading a run's context
requires no privileged access, and its write path is the only privileged one. Roles *use*
credentials but never persist them ([AD-15](architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs)).

**Cost attribution** — the platform is a cost centre, not just a cost reducer. Tagging is
mandatory at creation (I-3), not patched afterwards, because GCP cannot add labels to a running
instance ([C-02](architectural-decisions.md#2-requirement-conflict-register)). Orphan detection and showback depend on
tags being correct at create time.

---

## 4. Key Interfaces

The contracts between layers. Each is versioned and additive
([AD-20](architectural-decisions.md#ad-20-additive-schema-versioning-only)).

### 4.1 Interface: Adapter → Engine

```
Adapter                       Engine
   |                             |
   |-- POST contract + run_id -->|  GHA: workflow_dispatch(inputs, ref=<sha>)
   |                             |  AAP: POST /api/controller/jobs/<id>/launch/
   |                             |       {extra_vars: {run_context_id}, job_tags:{}}
   |                             |
   |<-- 202 {run_id, run_url} ---|  GHA: nothing (async, poll runs/<id>)
   |                             |  AAP: {id, url, status}
   |                             |
   |-- poll (backoff) --------->|  GHA: GET /repos/{o}/{r}/actions/runs/{id}
   |                             |  AAP: GET /api/controller/jobs/<id>/  + /unified_jobs/
   |                             |
   |<-- {status, run_url} ------|  status ∈ {queued,in_progress,completed}
   |                             |
   |-- terminal status -------->|  ServiceNow callback + run-state write
```

Only `run_context_id` crosses into AAP. Technical parameters live in the run-state store, so
they are not visible in the AAP job's extra-vars (which is where they would be exposed to a
wider audience than should see them) and are not re-enterable from the job detail UI.

### 4.2 Interface: Stage machine → Provider role

The provider role contract, in full ([role-dependency-model.md §3 ](role-dependency-model.md#3-the-provider-role-contract)):

```
INPUT (required)
  sba_provider              azure | aws | gcp            (closed enum)
  sba_operation             provision | get | validate | destroy
  sba_instance              { index, short_name, fqdn, sba_instance_id }
  sba_location              { region, zone, availability_zone }
  sba_network               { vpc_id, subnet_id, security_group_ids[], private_ip? }
  sba_compute               { size, disk_policy, os_disk_gb, data_disks[] }
  sba_image                 { catalog_id, provider, type, reference, version }
  sba_identity              { credentials_ref }          (name only, never a value)
  sba_tags                  { <business metadata> }       (TagMapper output)

OUTPUT (required, asserted by contract test)
  sba_facts.server          { instance_id, state, private_ip, fqdn, resource_group }
  sba_facts.network         { vpc_id, subnet_id, nic_id, private_ip, availability_zone }
  sba_facts.disk            { os_disk_id, data_disk_ids[], sizes_gb }
  sba_facts.image           { applied_image_id, applied_version, applied_digest }
  sba_result                { changed, status, duration_s, error_code? }

POSTCONDITIONS (asserted by the stage wrapper, not by the role)
  instance exists, is tagged tag-completely, has sba_instance_id, reports a private IP,
  and is reachable on the expected management port
```

### 4.3 Interface: Stage → Stage

Stages communicate only through `context.json` + `result.<stage>.json`. No stage reads
another stage's Ansible variables, and no stage depends on another having run in the same
process.

```
  stage N  ──reads──>  context.json          (immutable input + cumulative results)
           ──writes─>  result.<stage N>.json
           ──updates─> context.json         (additive fields only: allocated ids, fqdn, cmdb_id)
```

This is what makes stage re-entry ([AD-01](architectural-decisions.md#ad-01-single-entry-playbooks--staged-re-entry))
and cross-engine failover ([AD-21](architectural-decisions.md#ad-21-single-active-engine-per-run))
possible without a shared engine, because the interface is a file format, not an API.

---

## 5. Layering Violations to Reject in Review

| Anti-pattern | Why it is rejected | Correct alternative |
|---|---|---|
| Cloud module name outside `roles/provider/*` and `roles/image/*` | [R-08](enterprise-architecture.md#9-architecture-risk-register): the abstraction rots the first time one is allowed | Provider role, or extend the role contract |
| `when: cloud == 'azure'` in a stage playbook | Same | A provider capability flag from the resolver |
| A stage calling another stage's roles directly | Couples stages; breaks re-entry | Communicate via `result.<stage>.json` |
| Adapter containing a stage list | Reintroduces duplication ([AD-01](architectural-decisions.md#ad-01-single-entry-playbooks--staged-re-entry)) | `server_build.yml` owns the stage list |
| A survey carrying `vm_size` / `subnet` / `image` | Re-exposes technical parameters ([C-16](architectural-decisions.md#2-requirement-conflict-register)) | Resolver output in `context.json` |
| A secret in `extra_vars` / a workflow input | Leaks in job detail and logs ([AD-15](architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs)) | Credential store / OIDC |
| Resolver performing an HTTP call | Breaks purity, portability and unit tests ([AD-22](architectural-decisions.md#ad-22-resolver-is-read-only-and-side-effect-free)) | Pre-flight stage with read-only credentials |
| Parsing `context.json` in Jinja for a nested lookup | Reimplements the resolver in Jinja ([AD-03](architectural-decisions.md#ad-03-configuration-resolver-is-a-python-library-not-jinja)) | Add a resolver output key |
| Tagging after create | GCP cannot relabel a running instance ([C-02](architectural-decisions.md#2-requirement-conflict-register)) | `sba_tags` at create time |
| A `latest`/floating dependency reference | Non-reproducible builds (I-10) | Pinned version or digest |

---

## 6. Extension Points

How each likely extension is absorbed without modifying existing content.

| Extension | Change required | Files touched | Existing content modified? |
|---|---|---|---|
| New cloud (e.g. OCI, VMware) | 2 roles + 1 config file + 1 enum entry + 1 inventory plugin entry | `roles/provider/*`, `roles/image/*`, `configuration/clouds/`, resolver enum | No |
| New engine (Jenkins, Argo) | 1 adapter | `automation/<engine>/` | No |
| New OS family (Solaris, AIX) | 1 baseline role + 1 os config file | `roles/os/`, `configuration/os/` | No |
| New server role (e.g. `kafka`) | 1 config file | `configuration/server_roles/kafka.yml` | No |
| New region | 1 config file + a policy entry | `configuration/regions/`, `configuration/policies/` | No |
| New OS baseline (e.g. CIS v3) | 1 config file selecting a new version | `configuration/os/`, role defaults | No |
| New post-build step (e.g. load-balancer registration) | 1 stage + 1 role + 1 workflow/template step | `roles/`, `playbooks/`, `server_build.yml` stage table | Stage table only |
| New policy rule | 1 rule + 1 test | `configuration/policies/` | No |
| New consumer (chatbot, AI agent) | Nothing | — | No — the contract is the interface ([AD-02](architectural-decisions.md#ad-02-engine-neutral-run-contract-as-the-integration-seam)) |
| New HTTP API surface | 1 gateway service (optional) | New service | No ([AD-10](architectural-decisions.md#ad-10-no-automation-gateway-service-in-v1)) |

The recurring answer to "existing content modified?" is **no**, which is the practical test of
whether an abstraction is real. An abstraction that requires editing the orchestration to add a
provider is a naming convention, not an abstraction.

---

## 7. Next

- Layered lifecycle detail and status model: [request-lifecycle.md](request-lifecycle.md)
- Resolution hierarchy, merge semantics, naming, images: [configuration-resolution.md](configuration-resolution.md)
- Role dependency DAG and full role contract: [role-dependency-model.md](role-dependency-model.md)
- Provider detail: [provider-abstraction.md](provider-abstraction.md), [cloud/azure.md](cloud/azure.md), [cloud/aws.md](cloud/aws.md), [cloud/gcp.md](cloud/gcp.md)
