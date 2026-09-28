# Azure Implementation Notes

Status: **Phase 1 — Proposed**

Provider-specific detail for the Azure roles: `azure_vm`, `azure_image`, and the mapping from
canonical platform concepts to Azure resources.

Abstraction: [../provider-abstraction.md](../provider-abstraction.md).

---

## 1. Resource Mapping

| Canonical | Azure resource | Notes |
|---|---|---|
| Instance | `Microsoft.Compute/virtualMachines` | |
| Name | `sba_name` (the ≤15 short name) | Also the computer name, so the ≤15 limit is structural, not cosmetic |
| Region | `location`, e.g. `westeurope` | Immutable |
| Zone | `zones: ["1"]` | Optional; a zone-pinned VM cannot be live-migrated during a maintenance event |
| Size | `hardwareProfile.vmSize` | |
| Network | `Microsoft.Network/virtualNetworks/subnets` | Symbolic ref resolved at apply time |
| NIC | `Microsoft.Network/networkInterfaces` | |
| Public IP | `Microsoft.Network/publicIPAddresses` | Opt-in; the default is **no** public IP |
| NSG | `Microsoft.Network/networkSecurityGroups` | Attached to the NIC or the subnet |
| OS disk | `Microsoft.Compute/disks` (managed) | |
| Data disks | `Microsoft.Compute/disks` | |
| Image | `Microsoft.Compute/galleries/images/versions` or a marketplace image | See §4 |
| Key vault key | `Microsoft.KeyVault/vaults/keys` | A disk encryption set references it |
| Resource group | `sba-<app>-<env>-<scope>` | See §2 |
| Identity | `SystemAssigned` or `UserAssigned` | Only when the role needs one |
| Tags | Resource tags (512/256 chars, case-sensitive) | The least restrictive of the three clouds |

---

## 2. Resource Group Layout

One resource group per application per environment per scope, with a run-scoped child group for
the VM and its NICs.

```
  RG: sba-payments-prod-app                     (lifecycle: application-scoped)
    ├── subnets, NSGs, image gallery, disks      (shared, pre-created)
    └── RG: sba-payments-prod-app-pypa001        (lifecycle: per-server, deleted with the server)
          ├── virtualMachines/pypa001
          ├── networkInterfaces/nic-pypa001
          └── publicIPAddresses/...              (only if opted in)
```

| Choice | Rationale |
|---|---|
| Nested per-server RG | [RBAC](../../security/security-architecture.md#32-cloud-permission-shape-example-azure) at per-server granularity, so `svc-sba-destroy` can be denied on shared infrastructure. A `destroy` with a flat RG can only ever be all-or-nothing |
| RG name contains the short name | Matches the NetBIOS limit, so the RG name is computable at pre-flight and a name failure is caught before any resource exists |
| RG name ≤ 90 characters | The Azure limit, with room for `sba_` and the scope suffix |
| Tag on the RG as well as the child | `azure_rm_resourcegroup` does not support the resource provider's own tags, so the group is tagged through the generic `tags` parameter |

The per-server RG is the single most valuable decision in this section. It is what makes
[AD-12](../architectural-decisions.md#ad-12-canonical-workflows-live-in-githubworkflows)'s
"destructive operations use a narrower identity" implementable on Azure at all.

---

## 3. Capabilities Declaration

```yaml
sba_provider_capabilities:
  name: azure
  zones: true
  spot_instances: true
  max_metadata_key_length: 512
  max_metadata_value_length: 256
  max_metadata_count: 50
  metadata_case_sensitive: true
  metadata_allows_uppercase: true
  metadata_allows_special_chars: false
  immutable_after_create:
    - subscription
    - location
    - resource_group
    - subnet          # a NIC cannot move between subnets
    - image           # an OS change is a rebuild
  resize_without_reboot: [vm_size]
  resize_requires_deallocate: [root_volume_size_gb]
  encryption_key_rotatable: true
  delete_is_asynchronous: true
  delete_reports_not_found_as: empty_result
  max_boot_wait_seconds: 3600
```

Azure is the **least restrictive** of the three on metadata, so the TagMapper's binding
constraint is the *key name* character set (`_` and `-` only) rather than length. That is why the
canonical key set uses `sba_instance_id` rather than `sbaInstanceId`, and why the same key set is
applied to GCP.

---

## 4. Image Strategy

Three sources, in preference order.

| Priority | Source | When | Reference form |
|---|---|---|---|
| 1 | Shared Image Gallery, version pinned | Default for all gold images | `/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Compute/galleries/<gal>/images/<img>/versions/<ver>` |
| 2 | Marketplace image, version pinned | Some third-party software | `publisher:offer:sku:version` |
| 3 | Managed image | Legacy, not for new entries | A managed image ID |

```yaml
# configuration/images/windows.yml
- id: win-2025-enterprise
  provider: azure
  reference:
    gallery: sbagoldexuswesteurope
    image: win-server-2025
    version: "2025.09.01"
  product: Windows Server 2025
  os_family: windows
  generation: 2
  expires_at: 2027-09-01
  min_platform_version: 2.0
  hardened: true
```

`version` is always pinned. An unpinned `latest` would make a build non-reproducible, would break
the immutability check on re-run (the image would differ from the recorded one and produce
`OS_VERSION_MISMATCH` on a *no-op* re-run), and would allow a `latest` image to change the OS of
a running server on a converge. This is a direct consequence of
[AD-07](../architectural-decisions.md#ad-07-image-catalogue-with-pinning-and-expiry).

**Generations.** Gen2 is the default for new Linux images and required for secure boot with
Trusted Launch. A `generation` mismatch between the catalogue and the image is caught at
resolution, not at apply.

---

## 5. Network Defaults

| Setting | Default | Rationale |
|---|---|---|
| Public IP | **None** | Ingress through the approved hub (Azure Firewall / NVA). A public IP on a production server is a finding in most security baselines |
| NSG | Referenced, not created by the build | NSG rules are a security artefact with their own review cycle; a build that creates them can accidentally open one |
| Accelerated networking | On, if the size supports it | Latency for the payment workloads in the example |
| Host encryption | Per policy | Disk encryption with a Customer Managed Key, via a disk encryption set |
| Private DNS | Per catalogue | `privatelink` zones for storage and backup |
| Accelerated Private Link | Where available | Same rationale as above |
| NIC count | One, unless the catalogue says otherwise | Multi-NIC complicates destroy ordering for no benefit at this scale |

A build must never create a security group. It may reference one, and it must fail if the
referenced group does not exist — a missing NSG resolved to "no NSG" is how a server ends up
with no network controls at all.

---

## 6. Identity and Authentication

| Use | Mechanism | Identity |
|---|---|---|
| Platform → Azure | OIDC federation from AAP / GitHub Actions | `svc-sba-sba-dev`, `svc-sba-sba-nonprod`, `svc-sba-sba-prod` |
| Per-run scoping | `correlation_id` as an Azure deployment-scope tag, or a per-run MI | See §7 |
| VM → Azure (where needed) | Managed identity, `SystemAssigned` | `mi-sba-<app>-<env>` |
| Key Vault access | Managed identity RBAC, not a secret in extra-vars | `Key Vault Secrets User` |

Federated credentials, not client secrets. A client secret in AAP or in a GitHub secret is a
long-lived credential in a place that is not designed to hold credentials, and
[AD-15](../architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs) exists to prevent exactly
that. Full detail in [../../security/secret-management.md](../../security/secret-management.md).

---

## 7. Per-Run Least Privilege

Two options, with a recommendation.

| Option | Mechanism | Cost | Recommendation |
|---|---|---|---|
| A. Conditional access by tag | A custom Azure Policy: the production role is denied unless `correlation_id` matches a value present in the platform's run-state store | A policy assignable with a deny effect, plus a parameterised value | **Recommended** |
| B. Per-run managed identity | A user-assigned MI created and deleted per run; the prod role conditions on `principalId` | MI lifecycle automation, a permission to create MIs, and MI propagation delay | Where tag-based policy is unavailable, and only as a fallback. A per-run MI is strictly better than the prod identity having write access to the whole subscription with no run-level condition, which is the failure mode this is designed to prevent. |

Option A's weakness, stated plainly: the policy needs to read the run-state store to evaluate, and
a policy that depends on a network call to another system can fail open or fail closed depending
on how it is written. It must be written to **fail closed** — if the state store is unreachable,
deny — and that behaviour needs a specific test.

---

## 8. Stage Implementation Notes

### 8.1 `provision`

```yaml
# 1. preflight — no resources created
- azure_rm_resourcegroup_info:            # the subscription is reachable, identity is valid
- azure_rm_subscription_info:

# 2. lookup by tag, never by name
- azure_rm_resource:
    name: "{{ sba_name }}"
    resource_group: "{{ sba_instance_rg }}"
    list_resources: true                   # read-only; never a create path
  register: sba_existing

# 3. the azure_rm_* modules are create-or-update, so an adopted instance is converged
#    by the same task that would have created it. This is why the role does not branch
#    between a create path and an update path.
- azure_rm_virtualmachine:
    resource_group: "{{ sba_instance_rg }}"
    name: "{{ sba_name }}"
    location: "{{ sba_region }}"
    zones: "{{ sba_zones | default(omit) }}"
    size: "{{ sba_size }}"
    admin_username: "{{ sba_admin_username }}"      # Azure-local user
    admin_password: "{{ sba_admin_password }}"      # from the credential store, no_log
    network_interface_ids: [ "{{ nic_id }}" ]
    os_disk:
      name: "osdisk-{{ sba_name }}"
      caching: ReadWrite
      storage_account_type: Premium_LRS
      disk_size_gb: "{{ sba_root_volume_size_gb }}"
    image_reference: "{{ sba_image_reference }}"
    tags: "{{ sba_tags }}"                # sba_instance_id applied in the same call
  no_log: true
```

Two Azure specifics that this depends on:

**`azure_rm_*` modules are create-or-update.** This aligns with
[create-or-adopt](../idempotency.md#4-create-or-adopt): a re-run of the same task converges the
existing resource rather than failing on a name conflict. The explicit tag lookup before it is
still required, because the module will happily adopt a VM that the platform did not create.

**A privileged admin password is required at create time.** Azure has no "no password" VM. The
value therefore comes from the credential store at the moment of the call, with `no_log: true`,
and the credential is rotated immediately after the OS configuration stage installs the local
administrator. This is a genuine Azure constraint, not a design choice, and it is why
`bootstrap_admin_password` appears in the credential set
([../../security/secret-management.md §4.1 ](../../security/secret-management.md#41-credential-store-design)).

### 8.2 `wait_for_ready`

```yaml
# Provider-side state, polled with a bounded budget
- azure_rm_virtualmachine_info:
    name: "{{ sba_name }}"
    resource_group: "{{ sba_instance_rg }}"
  register: sba_vm_state
  until: sba_vm_state.state == "PowerState/running"
  retries: 30
  delay: 30          # 15 minutes, then the guest-agent check takes over
  no_log: true
```

Azure reports `PowerState/running` while WinRM is still installing on a first boot. Provider
readiness is therefore necessary but not sufficient; the guest-agent check in `os_config` is
what actually proves the server is usable, and it is what raises `WINRM_NOT_READY`.

### 8.3 `converge_instance`

| Change | Mechanism | Impact |
|---|---|---|
| Resize | `azure_rm_virtualmachine` with a new `size` | In place for most sizes |
| OS disk expand | Deallocate → modify disk → start | **A reboot.** Announce it, and never do it on a production payment server without a change |
| Retag | `azure_rm_resourcegroup` / a generic tags call | None |
| Key rotation | Update the disk encryption set | Azure re-encrypts asynchronously |

The OS disk case is the one to watch. Expanding a disk is a natural "just make it bigger" request
and a natural "reboot a production server" side effect. It is a change, not a converge.

### 8.4 `decommission`

Reverse creation order, restricted to `adopted: false`:

```
  1. delete the VM              (azure_rm_virtualmachine: state=absent)
  2. delete the NIC             (state=absent)
  3. delete the data disks      (state=absent)   — before the RG
  4. delete the per-server RG   (state=absent)
  5. delete the DNS record set
  6. delete the ServiceNow CI record
  7. remove the AD computer object (only if the run created it)
```

Deleting the resource group in step 4 would cover steps 1-3 in one call, and it is tempting. It
is also wrong: the group delete is asynchronous and reports success while resources are still
being removed, so a `not found` on the VM immediately afterwards looks like a partial failure, and
a name that becomes free before its disks do can be re-used by a new build while the old managed
disks are still deleting — billing for two. Explicit deletion in dependency order, with a wait
between the steps, is slower and correct.

**The RG name must be derived from the run state, not recomputed.** If the app code or the scope
has changed since the build, a recomputed name deletes a group that does not exist and leaves the
original running forever.

---

## 9. Error Mapping

| Azure condition | Platform code | Retryable |
|---|---|:--:|
| Request timeout, gateway | `CLOUD_API_TIMEOUT` | yes |
| `429`, `TooManyRequests` | `CLOUD_API_THROTTLED` | yes |
| `409`, `OperationNotAllowed`, `AnotherOperationInProgress` | `RESOURCE_CONFLICT` | yes |
| `429`, `QuotaExceeded` / `SkusNotAvailable` | `QUOTA_EXCEEDED` / `SIZE_NOT_AVAILABLE_IN_REGION` | no |
| `403`, `AuthorizationFailed` | `AUTHZ_DENIED` | no |
| `404` on a *read* | Treated as "does not exist" | n/a |
| `404` on a *delete* | Treated as success | n/a |
| `DiskEncryptionSetAccessDenied` | `ENCRYPTION_KEY_UNAVAILABLE` | no |
| `InvalidParameter`, `BadRequest` | `CLOUD_API_REJECTED` | no |
| `AllocationFailed`, `OverconstrainedAllocation` | `ZONE_CAPACITY_EXHAUSTED` | no |

The last row is worth distinguishing from a quota error. `AllocationFailed` for a specific
availability zone usually means the zone is at capacity for that VM size, and the correct
response is either a different zone or a different size — both of which are catalogue decisions
for a human. It is not retryable, and a retry just picks the same constrained zone again.

---

## 10. Naming and Tagging

| Limit | Value | Binding? |
|---|---|---|
| Computer name / hostname | 15 | **Yes** — `AD-2` |
| OS disk name | 512 | No |
| VM name | 64 | No |
| Tag key | 512 | No |
| Tag value | 256 | No |
| Tag count | 50 | Only if the catalogue is verbose |
| RG name | 90 | Only if app and scope names are long |

**Azure is the only one of the three where the 15-character limit is the binding constraint on
the name.** On AWS and GCP the limit is 63 for a tag value or a label, so the same short name
fits comfortably. The platform uses the short name as the VM name anyway
([AD-06](../architectural-decisions.md#ad-06-two-name-model-short-netbios-name--long-fqdn)), so the
constraint is uniform and the code is uniform — which is the point of
[AD-02](../architectural-decisions.md#ad-02-engine-neutral-run-contract-as-the-integration-seam).

```yaml
sba_tags:
  sba_instance_id: "{{ sba_instance_id }}"    # 36 chars, the ownership key
  sba_application: "{{ sba_application }}"
  sba_environment: "{{ sba_environment }}"
  sba_request_id: "{{ sba_request_id }}"
  sba_change_ref: "{{ sba_change_reference }}"
  sba_git_sha: "{{ sba_git_sha }}"
  sba_correlation_id: "{{ sba_correlation_id }}"
  sba_managed_by: sba
  sba_run_id: "{{ sba_run_id }}"
  owner: "{{ sba_owner }}"
  cost_center: "{{ sba_cost_center }}"
  data_classification: "{{ sba_data_classification }}"
  environment: "{{ sba_environment }}"        # a conventional alias for reporting
```

Azure tags cannot contain `<`, `>`, `%`, `&`, `\`, `?`, `/`. A cost centre or a data
classification containing a `/` fails at apply time, so the TagMapper validates the character
set per provider against the capability declaration and fails at **resolution** instead.

---

## 11. Security Checklist

| Check | Mechanism |
|---|---|
| Microsoft Defender for Cloud plan | Required; the platform reads its findings |
| Defender assessment on the subscription | Enabled, and a failed assessment is a `validate_os` finding |
| Disk encryption with CMK | Per policy, via a disk encryption set |
| Secure Boot / Trusted Launch | Per catalogue `provider_metadata` |
| Public IP absent | The default; a public IP requires a policy exception |
| NSG attached | Referenced, never created by a build |
| Diagnostic settings | Log Analytics for NSG flow logs, VM console, and the platform log |
| Azure Policy | Deny-by-default for public IPs, unencrypted disks, and untagged resources |
| JIT / Bastion | Operator access only. No inbound RDP, ever |
| Private endpoints | Where a PaaS resource is reachable |
| Resource lock on the per-server RG | `CanNotDelete` while the server is in production; removed by `destroy` |

The resource lock is the mechanism behind [AD-16](../architectural-decisions.md#ad-16-forward-fix-over-auto-destroy).
It is cheap, it is auditable, and it means the *protection* does not depend on the platform
software behaving correctly — which matters, because the platform software is what you are trying
not to trust with an accidental delete.

---

## 12. Next

- [provider-abstraction.md](../provider-abstraction.md) — the contract this implements
- [aws.md](aws.md), [gcp.md](gcp.md) — the peers
- [../../security/security-architecture.md](../../security/security-architecture.md) — IAM and R-08
- [../configuration-resolution.md §6 ](../configuration-resolution.md#6-naming-engine) — naming rules
