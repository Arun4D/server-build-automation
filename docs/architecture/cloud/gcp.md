# GCP Implementation Notes

Status: **Phase 1 — Proposed**

Provider-specific detail for the GCP roles: `gcp_compute`, `gcp_image`, and the mapping from
canonical platform concepts to GCP resources.

Abstraction: [../provider-abstraction.md](../provider-abstraction.md).

**This is the provider that required the most design work.** GCP has no availability-zone concept
for most services, its **labels** are severely constrained while **annotations** are not, and its
IAM does not support tag-based conditions on most resources. All three of those shape
[AD-11](../architectural-decisions.md#ad-11-gcp-labels-for-indexable-subset-annotations-for-full-metadata),
and this document is where that decision is paid for.

---

## 1. Resource Mapping

| Canonical | GCP resource | Notes |
|---|---|---|
| Instance | `compute.instances` | |
| Name | `instance.name` | A real API field, 63 chars, `[a-z]([-a-z0-9]*[a-z0-9])?` |
| Identifier | The fully-qualified name `<project>/<zone>/<instance>` | |
| Region | `<region>` for the regional endpoint; `<zone>` for a zonal one | |
| Zone | `zone` | Optional. Not applicable in every region |
| Size | `machineType` | Fully qualified: `<zone>/n2-standard-4` |
| Network | VPC network + subnet | By name or self link |
| NIC | Attached at create | Cannot be added after creation without a stop |
| Firewall | `compute.firewalls` | Referenced, never created by a build |
| External IP | `accessConfigs` | **Omitted by default** |
| Service account | Attached at create | Only when the role needs one |
| Scope | `compute-rw`, `logging-write` | As narrow as the role permits |
| Boot disk | Created at launch, or attached | |
| Data disks | `compute.disks` attached at create | |
| Image | A Compute Engine image, or a family/pinned name | |
| CMEK | `diskEncryptionKey` with a Cloud KMS key | |
| Labels | `labels` | **63 chars, lowercase, `[a-z0-9_-]`** |
| Annotations | `annotations` | Effectively unlimited |
| Project | The project in the resource path | |

---

## 2. Zones Are Not Zones

**GCP's `zone` is not the same concept as an Azure availability zone or an AWS AZ.** It is
simply the name of a deployment locality within a region — `europe-west1-b` — and there is no
concept of a capacity-isolated failure domain that a VM can be pinned to for high availability.

| | Azure / AWS | GCP |
|---|---|---|
| Concept | Availability zone: a physically isolated failure domain | Zone: a deployment locality |
| Isolation guarantee | Distinct power, cooling, networking | **No isolation guarantee.** The zones in a region may share infrastructure |
| High-availability implication | A multi-AZ deployment is genuinely fault-isolated | A multi-zone deployment is *not* guaranteed fault-isolated |
| Regional resources | Regional services exist; zonal resources are pinned | A regional persistent disk is replicated across zones |

Three consequences for the platform:

1. **The platform does not present "zone" as a resilience control to requesters.** A requester
   choosing `europe-west1-b` gets a locality, not an isolation promise. The requester-facing
   documentation must say so, or the platform will have promised something GCP does not provide.
2. **A "zone" may not exist in a region.** Some GCP regions have one zone; some have four. A
   catalogue entry naming a zone that does not exist in the target region must fail at
   **resolution**, not at apply.
3. **`zone_selection: first_available` is the right default.** For a multi-server batch, spreading
   across zones is still worthwhile — it avoids a single zone's capacity limit and spreads
   licences or quotas — but it is a *distribution* decision, not an availability one.

```yaml
# configuration/regions/gcp.yml
- id: europe-west1
  provider: gcp
  provider_region: europe-west1
  zones: [europe-west1-b, europe-west1-c, europe-west1-d]
  # Note: no isolation guarantee. Do not present this as a resilience control.
  zone_semantics: deployment_locality_only
  default_zone_selection: first_available
- id: europe-west4
  provider: gcp
  provider_region: europe-west4
  zones: [europe-west4-a, europe-west4-b]
  zone_semantics: deployment_locality_only
```

`zone_semantics` is a documentation field as much as a technical one. It exists so that the
requester-facing form and the ServiceNow flow can present the choice honestly.

---

## 3. Labels vs Annotations

[AD-11](../architectural-decisions.md#ad-11-gcp-labels-for-indexable-subset-annotations-for-full-metadata)
is the decision. GCP's two metadata mechanisms have completely different characteristics, and
conflating them is the single most common GCP mistake in a platform like this.

| | **Labels** | **Annotations** |
|---|---|---|
| Length | **63 characters per key and per value** | Effectively unlimited |
| Character set | Lowercase letters, digits, `_` and `-` only | Arbitrary UTF-8 |
| Key must start with | A lowercase letter | Any character, including uppercase (unusable by IAM conditions) |
| Usable in `gcloud --filter` | **Yes** | No |
| Countable in billing export | **Yes** | No |
| Changeable after creation | **No.** Requires a stop/start | **Yes** |
| Purpose | Machine-readable, filterable, policy-enforceable | Human-readable, arbitrary metadata |

### 3.1 The decision

```
  sba_instance_id  -> BOTH label and annotation
      Labels:    the IAM condition key. Without it, tag-based least
                 privilege is impossible on GCP.
      Annotation: unbounded length, so a full UUID or a long
                 correlation_id is always representable.

  every other canonical key -> BOTH label and annotation
      Labels:    for cost export and for --filter
      Annotations: the authoritative copy, for long values, mixed
                 case, and anything with a character the label
                 set rejects
```

`labels` is the source of truth for enforcement, `annotations` for completeness. The two are
kept identical by one function, [configuration-resolution.md §8 ](../configuration-resolution.md#8-tag-resolution--tagmapper),
and by [idempotency.md §4.3 ](../idempotency.md#43-the-tag-with-create-rule): the label is written
in the create call, and the annotations are written immediately after, then a read-back verifies
the label landed.

### 3.2 Why a read-back

GCP's compute API will accept a resource with a label that is *syntactically* valid but that was
silently dropped or normalised, and it will return `200` on the write. The `tags_converge` step
therefore re-reads the instance and asserts that `labels.sba_instance_id` equals the intended
value, failing with `TAG_WRITE_INCOMPLETE` if it does not. A silently missing ownership label
would make `create_or_adopt` return "not found" on the next run and create a duplicate — the
exact failure `AD-05` exists to prevent — and it would do so *after* the platform had reported
success.

### 3.3 The label-length problem, and how it is actually handled

`sba_correlation_id` (21 characters) fits. `sba_request_id` fits. `sba_instance_id` (36
characters) fits. **The keys that do not fit are the long ones a user would naturally want:**
`data_classification_confidential_restricted`, or a long `sba_git_sha_branch_name`, or a
`change_reference` with a prefix.

```
  Canonical value: "internal-confidential-restricted-data"        (39 chars, fits)
  Canonical value: "PCI-DSS-cardholder-data-cde-4482"             (35 chars, fits)

  But a value with capitals, e.g. "PCI-DSS Cardholder Data"      (26 chars, UPPERCASE)
  -> label rejects capitals; annotation keeps them.

  And a genuinely long one, e.g. a ServiceNow change ref
  "CHG0041234-PCI-DSS-CDE-4482-REMEDIATION-PLAN-FINAL"           (52 chars, fits)
```

The rules, applied in order:

1. Truncate the value to 63 characters, and record the original in the annotation.
2. Remove characters outside `[a-z0-9_-]`, and record the original in the annotation.
3. If the value is now empty, **omit the label entirely** and keep the annotation. An empty label
   is rejected by the API, and a placeholder is worse than an absence.
4. Record every transformation in `context.resolved.metadata_transformations[]`, so the
   transformation is reviewable in the golden resolution files.

The last rule is the one that matters. A silent truncation is a data-quality defect that will be
discovered later, by a cost report, with no way to explain what the original value was. Recording
the transformation means the reviewer sees it in the pull request, where it is a one-line change
to fix.

```json
{
  "provider": "gcp",
  "labels": {
    "sba_instance_id": "3f9c1e2a-7b4d-4c8e-9a1f-2d6b8e0c5a37",
    "sba_application": "payments",
    "sba_environment": "prod",
    "sba_correlation_id": "ritm-0041820"
  },
  "annotations": {
    "sba_instance_id": "3f9c1e2a-7b4d-4c8e-9a1f-2d6b8e0c5a37",
    "sba_application": "payments",
    "sba_environment": "prod",
    "sba_correlation_id": "ritm-0041820",
    "data_classification": "PCI-DSS Cardholder Data (CDE-4482)",
    "sba_change_ref": "CHG0041234-PCI-DSS-CDE-4482-REMEDIATION-PLAN-FINAL",
    "sba_git_sha_branch_name": "feature/payment-gateway-eu-westeurope-migration"
  },
  "metadata_transformations": [
    { "key": "data_classification", "to": "annotation", "reason": "uppercase_not_allowed_in_label" },
    { "key": "sba_change_ref", "to": "annotation", "reason": "length_exceeds_63" },
    { "key": "sba_git_sha_branch_name", "to": "annotation", "reason": "character_set" }
  ]
}
```

### 3.4 The IAM consequence

Labels can only be **set at creation**; a change requires a stop/start. That is a hard
architectural constraint on tag *updates*, and it shapes
[ad-15](../architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs)'s tag-converge
requirement:

| Case | What happens |
|---|---|
| All labels are already correct | `sba_labels_converged: true`; **no** stop, no start, no re-admission |
| One label is missing or wrong | A short stop / modify / start, announced as a **reboot-equivalent event** |
| One label was added by a human | A reboot-equivalent event to fix a mistake, recorded in the run |

**The `AD-11` invariant `I-6` states the first branch, and this is where it is actually
enforced.** Most label drifts are static, and the `sba_labels_converged` check means the
overwhelming majority of re-runs produce zero control-plane events. The rare case that needs a
stop/start is correct, recorded, and visible in the result artifact.

An important consequence for the cost of this: a GCP instance with an attached regional
persistent disk **cannot** be moved between zones without recreating the disk. So a label fix
that needs a zone change is not a converge at all — a label is immutable, and a tag fix never
implies a zone fix, so this is a case the platform should simply reject rather than attempt.

---

## 4. Capabilities Declaration

```yaml
sba_provider_capabilities:
  name: gcp
  zones: true
  zone_isolation_guaranteed: false      # see section 2
  spot_instances: true
  max_metadata_key_length: 512          # annotations
  max_metadata_value_length: 256
  max_metadata_count: 100
  metadata_case_sensitive: true
  metadata_allows_uppercase: true
  metadata_allows_special_chars: false
  label_key_length: 63                  # <-- the binding constraint on GCP
  label_value_length: 63
  label_allows_uppercase: false         # <-- the other binding constraint
  label_character_set: "[a-z0-9_-]"
  label_can_contain_length: 63
  label_readable_by_iam: true
  label_mutable_without_restart: false
  annotation_mutable_without_restart: true
  immutable_after_create:
    - project
    - region
    - zone
    - network
    - subnet
    - image
    - boot_disk_type       # PD types cannot be changed on an attached disk
  resize_without_reboot: [machine_type]
  resize_requires_deallocate: [boot_disk_size]
  encryption_key_rotatable: true        # Cloud KMS rotation
  delete_is_asynchronous: false
  delete_reports_not_found_as: api_error_requiring_normalisation
  max_boot_wait_seconds: 3600
```

The two `label_*` entries are GCP-specific and have no counterpart on the other two providers.
The TagMapper reads them from the active provider's declaration, so the logic stays in one place
and the difference stays data.

---

## 5. Image Strategy

| Priority | Source | Reference form | Notes |
|---|---|---|---|
| 1 | A self-built image family with a **pinned version** | `projects/<proj>/global/images/<image>` | Preferred. Version-pinned, not `latest` |
| 2 | A project image, pinned | `projects/<proj>/global/images/<image>` | |
| 3 | A GCP-published image | A family or a self link | The only case where a family is acceptable, because a GCP-published image is a vendor-supported artifact with its own lifecycle |

```yaml
# configuration/images/ubuntu.yml
- id: ubuntu-2204-standard
  provider: gcp
  product: Ubuntu 22.04 LTS
  os_family: linux
  expires_at: 2029-04-30
  reference:
    project: sbagoldimages
    image: ubuntu-2204-lts-gold-v20260901
  # NOT latest. A family would make the build non-reproducible and
  # would make a no-op re-run report OS_VERSION_MISMATCH.
  build_date: "2026-09-01"
  guest_os_features:
    - type: SEV_LAUNCH      # confidential computing; requires a supported machine type
```

**`latest` is never used for a catalogue entry.** A family like `ubuntu-2204-lts-gold` is a moving
reference, and a moving reference on a run whose idempotency check compares the *current* image to
the *recorded* one produces `OS_VERSION_MISMATCH` on every no-op re-run. The catalogue pins the
exact image name, and the platform resolves it to a self link at apply time so the recorded value
is unambiguous.

The family is recorded alongside the resolved self link in `context.resolved`, so a `DescribeImage`
comparison is exact rather than approximate.

---

## 6. Network Defaults

| Setting | Default | Rationale |
|---|---|---|
| External IP | **Omitted** | Private instances with Cloud NAT. A public IP on a production server is a finding in most baselines |
| Firewall rules | Referenced, never created by the build | A firewall rule is a security artefact with its own review cycle |
| Private Google Access | Enabled on the subnet | Prevents traffic leaving via the public IP path, which bypasses the organisation's egress controls |
| Cloud NAT | Per subnet or per region | A build must not create one; it is a network change |
| VPC-native DNS | Enabled | For private service access |
| Private Service Connect | Where a PaaS is reachable privately | |

A GCP-specific trap: **creating a VPC-native cluster or a Private Service Connect allocation
consumes a limited IP range.** If a build were to create one, it could exhaust the range for
everything else in the network. This is the GCP analogue of the subnet-exhaustion problem in
[azure.md §6 ](../configuration-resolution.md#6-naming-engine), and the rule is the same: the platform
references networking, it never creates it.

---

## 7. Identity and Authentication

| Use | Mechanism | Identity |
|---|---|---|
| Platform → GCP | OIDC federation, or a workload identity pool | `svc-sba-sba-dev`, `-nonprod`, `-prod` |
| Per-run scoping | `labels` + an IAM condition on `resource.labels.sba_instance_id` | See §8 |
| VM → GCP | A service account attached at create | `sba-payments-prod@<proj>.iam.gserviceaccount.com` |
| CMEK access | The service account's role on the KMS key | `roles/cloudkms.cryptoKeyEncrypterDecrypter` |

GCP's IAM Conditions **can** reference `resource.labels`, which is the whole reason `sba_instance_id`
must be a label and not only an annotation. This is the one place where a label's 63-character
limit interacts with security, and it is a good illustration of why the split exists: the
unbounded annotation holds the full value, and the bounded label holds the key that the IAM
condition needs.

### 7.1 The service account

| Rule | Reason |
|---|---|
| Never the default compute SA | The default has broad project-wide permissions and no ownership |
| Never a user-managed SA with `Owner` | n/a |
| `automount` only when the role needs GCP access | A mounted token on a server that does not need it is an unnecessary credential |
| Scope `compute-rw` + `logging-write` at most | The narrowest that lets the intended work succeed |
| Separate SA per application per environment | Blast radius, and a readable cost allocation |

An automated server build platform that attaches a broadly-privileged service account to every
server it creates would be handing out project-wide credentials as part of its normal operation.
The per-role SA rule is what prevents that, and it is worth stating as an `AUTHZ.md` requirement
rather than a convention.

---

## 8. Per-Run Least Privilege

| Mechanism | How | Note |
|---|---|---|
| **IAM condition on `resource.labels.sba_instance_id`** | `resource.name.startsWith(...)` plus `resource.labels.sba_instance_id == "<id>"` | **The only tag-based mechanism on GCP**, and the reason labels are mandatory. It works on `compute.instances` and `compute.disks` |
| Scope restriction | `resource.name.startsWith("projects/<proj>/zones/<zone>/instances/<name>")` | A name-based complement to the label condition |
| Org policy | Deny `compute.instances.create` outside the platform's service accounts | The outer boundary |
| `compute.restrictXpnProjectLienRemoval` | Prevents cross-project changes | |

An example of the production role, showing both parts:

```json
{
  "role": "roles/compute.instanceAdmin.v1",
  "condition": {
    "title": "sba-prod-run-scoped",
    "expression": "resource.labels.sba_instance_id == '3f9c1e2a-7b4d-4c8e-9a1f-2d6b8e0c5a37'",
    "iam_token": { "include_current_time": true, "expiration_time": "2026-09-28T18:00:00Z" }
  }
}
```

**The limitation to state plainly:** a GCP conditional binding needs a **condition-specific IAM
role** (`iam.serviceAccounts.getIamPolicy` on the condition object), so the per-run binding is
itself an IAM operation with a lifecycle. The platform therefore holds a narrow
`roles/iam.serviceAccountUser`-equivalent scope for creating and deleting its own conditional
bindings, and a role that can create conditional bindings can also create *unconditional* ones.
That is a real escalation path, and it is why the prod identity's ability to create IAM bindings
is called out in `AUTHZ.md` as one of the highest-risk grants in the whole estate.

**A dead-simple alternative, and why it is not used:** a bare
`projects/<proj>/zones/<zone>/instances/<name>` scope is far easier to audit. It is rejected
because a name is *derived*, and a derived scope does not survive a name change, a
re-adoption, or a drift; a tag-based scope is bound to the identity of the resource. For
short-lived, disposable build targets the name scope is adequate, and the platform is
deliberately not the place to make that trade-off on the reviewer's behalf.

---

## 9. Stage Implementation Notes

### 9.1 `provision`

```yaml
# 1. lookup by label, never by name
- google.cloud.compute_instance_info:
    project: "{{ gcp_project }}"
    zone: "{{ gcp_zone }}"
    filter: "labels.sba_instance_id={{ sba_instance_id }}"
  register: sba_existing

# 2. absent -> create. Present -> adopt and converge.
- google.cloud.compute_instance:
    name: "{{ sba_name }}"                  # <= 63, [a-z]([-a-z0-9]*[a-z0-9])?
    project: "{{ gcp_project }}"
    zone: "{{ gcp_zone }}"
    machine_type: "{{ gcp_zone }}/{{ sba_size }}"
    can_ip_forward: false
    # No access_configs => no external IP. This is the default.
    network_interfaces:
      - network: "{{ gcp_network }}"
        subnetwork: "{{ gcp_subnetwork }}"
        # no access_configs: deliberate
    disks:
      - source: "{{ boot_disk_self_link }}"
        boot: true
        auto_delete: true
        disk_encryption_key_raw: "{{ sba_cmek_key | default(omit) }}"
    labels: "{{ gcp_labels }}"              # sba_instance_id at CREATE time
    metadata:
      block-project-ssh-keys: "true"
      enable-oslogin: "TRUE"                # OS Login, not key files
      items: "{{ sba_metadata_items }}"     # startup script, rendered by the platform
    service_accounts:
      - email: "{{ sba_gcp_service_account | default(omit) }}"
        scopes: "{{ sba_gcp_scopes | default(omit) }}"
    deletion_protection: false              # destroy must be able to remove it
    state: present
  register: sba_create_result
  no_log: true

# 3. annotations AFTER create: labels cannot be added without a stop/start
- google.cloud.compute_instance:
    name: "{{ sba_name }}"
    zone: "{{ gcp_zone }}"
    project: "{{ gcp_project }}"
    annotations: "{{ gcp_annotations }}"
  register: sba_annotate_result

# 4. READ BACK and assert the label landed
- google.cloud.compute_instance_info:
    project: "{{ gcp_project }}"
    zone: "{{ gcp_zone }}"
    name: "{{ sba_name }}"
  register: sba_verify_labels
  failed_when: >-
    sba_verify_labels[0].labels.sba_instance_id | default('') != sba_instance_id
```

Steps 3 and 4 are the GCP-specific tail, and they exist because of
[§3.1 ](#31-the-decision)'s asymmetry. Every other provider applies its full metadata in the create
call; GCP applies the label there and the annotations immediately after, and then proves the
label is present. A failure at this point raises `UPDATE`, which is
**terminal** ([failure-and-retry.md §4.2 ](../failure-and-retry.md#42-not-retryable--and-why)) —
continuing past a missing ownership label would produce a server the platform cannot subsequently
manage or safely destroy.

**`metadata.items` renders the startup script from the catalogue**, not from a user-supplied
value. GCP metadata is a plain-text key/value store that the instance can read, and a requester
who can put an arbitrary value in it can put an arbitrary startup script on a production server.
The value is always platform-rendered from a reviewed catalogue entry.

### 9.2 `converge_instance`

| Change | Mechanism | Impact |
|---|---|---|
| Machine type | `set-machine-type` | Often requires a stop. Must be tested per family |
| Disk size | Create a larger disk, copy, switch | **Not a converge.** A change |
| CMEK | Set `diskEncryptionKey` on a new disk | Cloud KMS rotation is automatic for the key; changing the key for a disk is a replacement |
| Add a label | Stop, modify, start | **Reboot-equivalent.** See [§3.4 ](#34-the-iam-consequence) |
| Modify an annotation | In place, no restart | None |
| Move zone | Impossible | Immutable, and a zone change invalidates a regional disk's placement |
| Add a network interface | Impossible without a stop | Effectively immutable |

The machine-type row deserves a note: GCP will stop a VM for a machine-type change in most cases,
and will refuse it in others. The platform treats a machine-type change as a change requiring a
request, and never as a converge, because "resize" here is sometimes a stop/start and silently
rebooting a production payment server is not something to discover from a playbook.

### 9.3 `decommission`

```
  1. delete the instance       (state: absent, deletion_protection already false)
  2. delete the data disks     (after the instance detaches them)
  3. delete the DNS record set
  4. delete the ServiceNow CI record
  5. remove the AD computer object (only if the run created it)
```

GCP has no network interface resource to delete separately; they are inline in the instance. That
makes GCP the simplest of the three to destroy, and it is worth remembering that a simpler
destroy is a reason to be *more* careful about ownership, not less: it is very easy to delete a
GCP instance by name, and the tag-based ownership check is the only thing preventing that.

---

## 10. Error Mapping

| GCP condition | Platform code | Retryable |
|---|---|---|
| Deadline exceeded, 504 | `CLOUD_API_TIMEOUT` | yes |
| 429, `RESOURCE_EXHAUSTED`, rateLimitExceeded | `CLOUD_API_THROTTLED` | yes |
| 409, `OperationInProgress` | `RESOURCE_CONFLICT` | yes |
| 403, `PERMISSION_DENIED` | `AUTHZ_DENIED` | no |
| 403, `ZONE_RESOURCE_POOL_EXHAUSTED` | `ZONE_CAPACITY_EXHAUSTED` | no |
| 429, `RATE_LIMIT_EXCEEDED` on CPU quota | `QUOTA_EXCEEDED` | no |
| 400, `INVALID_ARGUMENT` | `CLOUD_API_REJECTED` | no |
| 400, `invalidLabels`, label validation | `METADATA_REJECTED` | no |
| 404 on a read | Does not exist | n/a |
| 404 on a delete | Normalised to success | n/a |
| `compute.instances` not found in a zone | `ZONE_NOT_AVAILABLE` | no |
| 403, `SERVICE_DISABLED` | `PROVIDER_FEATURE_NOT_ENABLED` | no |
| `resourceInUseByAnotherResource` on a disk delete | A bounded retry | yes |
| IAM condition evaluation failure | `AUTHZ_DENIED` — fail **closed** | no |

Two rows are GCP-specific and both are quiet failure modes. `invalidLabels` is a
`400` at create time, so a malformed label produces a confusing provider error rather than a
clear platform one — the TagMapper's job is to prevent that, not to translate it.
And an IAM condition that fails to evaluate, for example because the label the condition reads
does not exist yet, must **deny**; a fail-open policy here would grant the prod role write access
to resources that carry no ownership label at all, which is the entire estate.

---

## 11. Naming and Tagging

| Limit | Value | Binding? |
|---|---|---|
| Instance name | 63, `[a-z]([-a-z0-9]*[a-z0-9])?` | **Yes** — lowercase, and the guest hostname must match |
| Label key / value | 63, `[a-z0-9_-]`, lowercase | **Yes** — the platform's main constraint |
| Annotation key / value | Effectively unlimited | No |
| Machine type | Region + zone qualified | Only if unqualified |
| Disk name | 63 | No |
| Firewall name | 63 | No |

**The instance name must be lowercase**, and it is the guest hostname. `pypa001` is fine;
`PYPA001` is not, and neither is `pypa-001-app`. The platform's generated names are always
lowercase, and a catalogue entry that tries to set a name directly rather than supplying a code
is rejected.

```yaml
gcp_labels:                       # sba_instance_id is ALWAYS here
  sba_instance_id: "{{ sba_instance_id }}"
  sba_application: "{{ sba_application }}"
  sba_environment: "{{ sba_environment }}"
  sba_request_id: "{{ sba_request_id }}"
  sba_change_ref: "{{ sba_change_ref }}"
  sba_git_sha: "{{ sba_git_sha }}"
  sba_correlation_id: "{{ sba_correlation_id }}"
  sba_managed_by: sba
  sba_run_id: "{{ sba_run_id }}"
  owner: "{{ sba_owner }}"
  cost_center: "{{ gcp_label_safe(sba_cost_center) }}"   # normalised
  data_classification: "{{ gcp_label_safe(sba_data_classification) }}"

gcp_annotations:                  # authoritative, unbounded
  sba_instance_id: "{{ sba_instance_id }}"
  sba_correlation_id: "{{ sba_correlation_id }}"
  sba_change_ref: "{{ sba_change_ref }}"
  sba_git_sha_branch_name: "{{ sba_git_branch }}"
  cost_center: "{{ sba_cost_center }}"                   # original
  data_classification: "{{ sba_data_classification }}"   # original
```

`sba_run_id` is a **label**, not an annotation. A run ID changes on every attempt, and an
annotation is freely mutable while a label is not — so a mutable `sba_run_id` label would require
a stop/start on every re-run. Keeping it in the label set but never *correcting* it is fine: the
ownership key is `sba_instance_id`, and `sba_run_id` is informational, so a stale value on a
re-run is harmless and the alternative is a reboot.

---

## 12. Security Checklist

| Check | Mechanism |
|---|---|
| No external IP | The default; the role has no `accessConfigs` path without a policy exception |
| OS Login enabled | `enable-oslogin: TRUE`; no SSH key files |
| Block project-wide SSH keys | `block-project-ssh-keys: true` |
| Service account with narrow scopes | Per app per env; not the default SA |
| CMEK where the policy requires it | `diskEncryptionKeyRaw` with a Cloud KMS key |
| Shielded VM | Secure Boot and vTPM per catalogue `provider_metadata` |
| VPC Service Controls | Where a regulated data boundary requires it |
| Private Google Access | Enabled, so traffic cannot egress via the public IP |
| Org policies | Deny `compute.instances.create` outside the platform's SAs; deny external IPs |
| Organization Policy for a label | A `constraints/compute.requireOsLogin` and a custom label policy |
| Binary Authorization | If a container image is ever deployed by a role |
| Cloud Asset Inventory | The source for the daily orphan sweep |
| Audit Logs | Admin-activity logs for every create/delete; data-access for the secret-bearing APIs |
| Access Transparency, Access Approval | If the prod SA is a third-party principal |

**Shielded VM (Secure Boot + vTPM)** is the GCP equivalent of what Azure offers through Trusted
Launch, and it is enabled per catalogue entry rather than globally, because not every machine
type supports it. A catalogue entry that requests it for an unsupported type must fail at
resolution.

---

## 13. Next

- [provider-abstraction.md](../provider-abstraction.md) — the contract this implements
- [azure.md](azure.md), [aws.md](aws.md) — the peers
- [configuration-resolution.md §8 ](../configuration-resolution.md#8-tag-resolution--tagmapper) — TagMapper
- [../idempotency.md](../idempotency.md) — create-or-adopt, tag-with-create
