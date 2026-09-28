# Provider Abstraction

Status: **Phase 1 — Proposed**

The contract every cloud role implements, the canonical resource lifecycle, the four operations
the platform needs, and why the abstraction is a *role contract* rather than a code-level SDK
wrapper.

Related: [role-dependency-model.md](role-dependency-model.md),
[AD-08](architectural-decisions.md#ad-08-provider-abstraction-via-a-fixed-contract--role-allow-list),
[cloud/azure.md](cloud/azure.md), [cloud/aws.md](cloud/aws.md), [cloud/gcp.md](cloud/gcp.md).

---

## 1. Why a Contract, Not a Base Class

[AD-08](architectural-decisions.md#ad-08-provider-abstraction-via-a-fixed-contract--role-allow-list)
fixed the shape of this: every provider role implements the **same named tasks, with the same
parameters and the same defaults**, and the playbook dispatches by static `include_tasks`.

```
                    ┌──────────────────────────────┐
                    │   playbooks/stages/provision  │
                    │   cloud_provider: azure       │
                    │   → include_tasks:            │
                    │       roles/cloud/azure_vm/   │
                    │         tasks/main.yml        │
                    └───────────────┬──────────────┘
                                    │ same task names,
                                    │ same args, for all three
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
              azure_vm         aws_ec2          gcp_compute
              main.yml          main.yml         main.yml
```

**Why not a Python class hierarchy.** Three reasons, and the third is decisive:

1. **The dispatch already happens in YAML.** A subclass hierarchy would require
   `set_fact`-driven dynamic includes to use it, which reintroduces exactly the dynamic
   role resolution that `AD-08` prohibits for security reasons. The abstraction would have to
   be undone at the dispatch point to be usable.
2. **The contract is data.** A role contract is a list of task names and defaults. It is
   reviewable in a diff, checkable by a CI script, and enforceable by `ansible-lint`. A base
   class is none of those.
3. **The cloud modules are the SDK.** `azure_rm`, `amazon.aws`, and `google.cloud` are three
   large, independent upstream codebases. Wrapping them behind a `CloudProvider` class means
   writing — and maintaining — three thin adapters over three fat SDKs, and the adapter becomes
   the layer where provider bugs hide. Using the real modules directly means upstream bug fixes
   and security patches arrive with an EE rebuild, and the abstraction layer stays thin enough
   to read.

The cost is that the contract is enforced by convention and review rather than by a type
system. §8 specifies how that is made reliable.

---

## 2. The Role Contract

Six task groups. Identical across `azure_vm`, `aws_ec2`, and `gcp_compute`.

| Group | Task | Purpose | Idempotency |
|---|---|---|---|
| **A. Lookup** | `preflight` | Validate the cloud account, region, and quota are usable. No resources created | Pure |
| | `lookup_instance` | Find the instance by `sba_instance_id` tag. `found: yes\|no` | Read-only |
| | `verify_immutable` | Assert subscription/project, region, network, and image cannot differ. Fail with `IMMUTABLE_MISMATCH` | Read-only |
| **B. Create/Adopt** | `resolve_image` | Map the catalogue image entry to a provider image reference | Read-only |
| | `create_instance` | **Create with tags applied atomically**, or adopt an existing instance | Create-or-adopt |
| | `attach_networking` | NIC/ENI/subnet, public IP, NSG/firewall/security group | Create-or-adopt |
| | `attach_storage` | OS disk, data disks, encryption, IOPS/throughput | Create-or-adopt |
| | `record_observed` | Write provider resource IDs into the run state | Append |
| **C. Converge** | `converge_instance` | Resize, retag, relabel, re-encrypt. Mutable attributes only | Idempotent update |
| **D. Post-provision** | `wait_for_ready` | Provider-side provisioning state plus a guest-agent check | Read-only + retry |
| **E. Decommission** | `list_owned_resources` | Every resource carrying this `sba_instance_id` | Read-only |
| | `delete_instance` | Delete in reverse creation order. **Only `adopted: false`** | Idempotent |
| **F. Verify** | `assert_instance` | The stage assertion for `provision` | Read-only |

### 2.1 Shared parameters

Identical names, identical meaning, in all three roles:

```yaml
sba_instance_id: "{{ sba_run_context.instance_id }}"
sba_name:         "{{ sba_run_context.name }}"          # short_name, <= 15
sba_fqdn:         "{{ sba_run_context.fqdn }}"
sba_region:       "{{ sba_run_context.region }}"
sba_image:        "{{ sba_resolved.image }}"           # provider reference
sba_size:         "{{ sba_resolved.size }}"
sba_subnet:       "{{ sba_resolved.subnet }}"          # symbolic ref
sba_availability_zone: "{{ sba_resolved.availability_zone }}"
sba_root_volume_size_gb: "{{ sba_resolved.root_volume_size_gb }}"
sba_data_volumes: "{{ sba_resolved.data_volumes }}"
sba_encryption_key_id: "{{ sba_resolved.encryption_key_id }}"
sba_network_security: "{{ sba_resolved.network_security }}"
sba_provider_metadata: "{{ sba_resolved.provider_metadata }}"
sba_tags:         "{{ sba_run_context.tags }}"        # includes sba_instance_id
```

`zone` and `availability_zone` must be **both** accepted. Accepting only one is a portability
trap that every provider hits differently: Azure has zones, AWS has AZs, and GCP has zones in
some regions and behaves differently in others. The platform accepts either, resolves the rest
from the provider, and treats an unresolvable combination as a catalogue error.

### 2.2 Shared defaults

```yaml
sba_retry_attempts: 3
sba_retry_delay: 5
sba_delete_timeout: 1800        # seconds
sba_wait_ready_timeout: 3600
```

Defaults are declared once, in the playbook, and passed explicitly. A default inside a provider
role is invisible to a caller reading the playbook, which defeats the point of having defaults.

---

## 3. The Four Operations

The platform needs exactly four things from a cloud. Everything else is provider detail.

### 3.1 `create_or_adopt(instance_id, spec)`

```
  lookup(instance_id) →
    none            → create(spec with sba_instance_id tag) → return (adopted=false)
    exactly one     → verify_immutable → converge →         return (adopted=true)
    more than one   → AMBIGUOUS_RESOURCE
```

[Idempotency.md §4 ](idempotency.md#4-create-or-adopt). Note that the lookup is **by tag**, never
by name, and that ambiguity is an error rather than a choice.

### 3.2 `converge(instance_id, spec)`

Update mutable attributes to match. Never creates, never deletes, never touches an immutable
attribute.

| Attribute | Converge? |
|---|---|
| VM size | Yes, if the API allows an in-place resize |
| Tags / labels | Yes |
| OS disk size | Yes — Azure requires deallocate/resize/start |
| Data disk size | Yes, expand only. Never shrink |
| Encryption key | Yes, if the API allows rotation without a re-encrypt |
| Network / subnet | **No** — immutable |
| Region | **No** — immutable |
| Image | **No** — a rebuild, not a converge |

### 3.3 `decommission(instance_id)`

Reverse-creation-order deletion, restricted to resources the run created. Full contract in
[idempotency.md §10 ](idempotency.md#10-compensating-actions).

### 3.4 `assert(instance_id, spec)`

The read-only stage assertion. It re-reads live provider state and compares it with the resolved
spec, and it fails on any mismatch. A stage assertion that does not actually assert is worse
than none, because it converts an unverified assumption into a recorded success.

---

## 4. Canonical Lifecycle

```
  ┌────────┐   ┌────────┐   ┌──────────────┐   ┌────────────┐   ┌──────────┐
  │PENDING │──▶│CREATING│──▶│PROVISIONING  │──▶│RUNNING    │──▶│DELETING  │──▶ ┌────────┐
  └────────┘   └───┬────┘   └──────┬───────┘   └─────┬──────┘   └────┬─────┘    │DELETED │
                   │               │                 │               architectural-decisions.md §3              │               │ timeout         │                │
                   ▼               ▼                 ▼                ▼
              ┌─────────┐     ┌──────────┐     ┌──────────┐    ┌──────────┐
              │FAILED   │     │TIMED_OUT │     │FAILED    │    │FAILED   │
              │(nothing │     │(retain)  │     │(retain)  │    │(partial) │
              │ created)│     └──────────┘     └──────────┘    └──────────┘
              └─────────┘
```

### 4.1 Provider vocabulary mapping

The platform's states are canonical. Provider states are mapped in, never exposed.

| Platform state | Azure | AWS | GCP |
|---|---|---|---|
| `PENDING` | — | `pending` | `PROVISIONING` |
| `CREATING` | `Creating` | `pending` | `PROVISIONING` |
| `PROVISIONING` | `Provisioning` | `pending` | `STAGING` |
| `RUNNING` | `VM running` | `running` | `RUNNING` |
| `DELETING` | `Deleting` | `shutting-down`/`terminated` | `STOPPING`/`DELETING` |
| `DELETED` | `Deleted` (not returned) | `terminated` | `DELETED` (not returned) |

A provider state with no mapping is `UNKNOWN`, and `UNKNOWN` is treated as
`PROVISIONING` with a bounded timeout rather than as success or as a failure. Guessing wrong
either way is worse than waiting.

### 4.2 The two timeout behaviours

| Situation | Behaviour | Rationale |
|---|---|---|
| Create did not return a provider ID | Wait up to `create_timeout`, then `COMPENSATE` | Nothing to clean up but the attempt |
| Create returned a provider ID, later step failed | **Retain** | The resource exists; `AD-16` |

`COMPENSATE` and `destroy` are different operations with different authorisation
([idempotency.md §10 ](idempotency.md#10-compensating-actions)). Conflating them is how a failed
build ends up taking down a server somebody else was using.

---

## 5. Provider Metadata

`provider_metadata` is a pass-through map from the catalogue. It is the **only** escape hatch in
the contract, and it is deliberately narrow.

```yaml
# configuration/server_roles/payment_gateway.yml
provider_metadata:
  azure:
    zones: ["1", "2", "3"]
    accelerated_networking: true
    host_group_id: "rg-payments-prod-hosts-01"
    patch_mode: ImageDefault
  aws:
    instance_profile: "sba-payments-prod-node"
    ebs_iops: 3000
    ebs_throughput: 125
    placement_group: "pg-payments-prod-01"
  gcp:
    # GCP has no AZ concept, so zone selection is a capacity decision, not a placement one
    zone_selection: first_available
    network_tags: ["sba", "payments", "prod"]
    gke_node_pool_labels: {}
    shielded_instance_config:
      enable_secure_boot: true
      enable_vtpm: true
```

### 5.1 Rules

| Rule | Reason |
|---|---|
| Unknown keys under a **known provider** → hard error | A typo in `accelerated_network` must not silently do nothing |
| Unknown **providers** are allowed and ignored | Forward compatibility: a catalogue that works on Azure-only must still resolve |
| Provider values are never merged with a role default silently | A merge hides which value won; the resolver reports the winner |
| No cross-provider leakage | An AWS catalogue entry must not influence Azure |
| Filled by the resolver, not by a role | Keeps the resolver pure ([AD-22](architectural-decisions.md#ad-22-resolver-is-read-only-and-side-effect-free)) |

The first rule is the important one, and it is the difference between a metadata escape hatch and
a silent failure generator. `AZ-1` in
[architectural-decisions.md §3 ](architectural-decisions.md#3-cross-cutting-invariants)
is what makes it enforceable.

---

## 6. Capability Declaration

Each provider role declares its capabilities, and the resolver uses them to validate a catalogue
entry at resolution time rather than failing at apply time.

```yaml
# roles/cloud/azure_vm/vars/main.yml — the role's capability declaration
sba_provider_capabilities:
  name: azure
  regions: "{{ lookup('sba_file', 'configuration/regions/azure.yml') }}"
  zones: true
  spot_instances: true
  # Max tag key length. Azure: 512. AWS: 128. GCP *labels*: 63 (lowercase only)
  max_metadata_key_length: 512
  max_metadata_value_length: 256
  max_metadata_count: 50
  metadata_case_sensitive: true
  metadata_allows_uppercase: true
  metadata_allows_special_chars: false
  immutable_after_create: [region, subscription, subnet, image, resource_group]
  resize_without_reboot: [size]
  resize_requires_deallocate: [root_volume_size_gb]
  encryption_key_rotatable: true
  delete_is_asynchronous: true
  delete_reports_not_found_as: empty_result
  max_boot_wait_seconds: 3600
```

### 6.1 Why `max_metadata_*` is the most important entry

[AD-11](architectural-decisions.md#ad-11-gcp-labels-for-indexable-subset-annotations-for-full-metadata)
is the decision that this serves. GCP **labels** are limited to 63 characters, lowercase
alphanumerics and dashes, and are the only metadata readable by GCP IAM conditions. GCP
**annotations** are unlimited. AWS tags allow 128 characters and are case-sensitive. Azure tags
allow 512 characters.

The platform therefore computes the metadata set, applies the provider's limits, and
**fails resolution** if a canonical key cannot be represented:

```yaml
sba_instance_id: 3f9c1e2a-7b4d-4c8e-9a1f-2d6b8e0c5a37   # 36, fits everywhere
application:    payments
environment:    prod
```

Failing at resolution rather than at apply is deliberate. A GCP label overflow discovered at
apply time means a half-created VM; the same overflow discovered at resolution means a
`VALIDATION_FAILED` with no infrastructure at all, and it costs the requester nothing.

### 6.2 Capability use

| Capability | Used by | On violation |
|---|---|---|
| `max_metadata_key_length` | TagMapper | `METADATA_KEY_TOO_LONG` at resolution |
| `max_metadata_count` | TagMapper | `METADATA_LIMIT_EXCEEDED` |
| `metadata_allows_uppercase` | TagMapper (GCP labels) | Normalised, with the normalisation reported |
| `zones` | `resolve_placement` | `ZONE_NOT_AVAILABLE` |
| `immutable_after_create` | `verify_immutable` | `IMMUTABLE_MISMATCH` |
| `resize_requires_deallocate` | `converge_instance` | A deallocate/resize/start cycle, announced |
| `delete_reports_not_found_as` | `delete_instance` | Normalised to success; deleting twice must succeed |
| `max_boot_wait_seconds` | `wait_for_ready` | `TIMEOUT` with the stage named |

The last row matters more than it looks: a Windows server with a long pending-reboot chain can
legitimately exceed a naive timeout, and a timeout that fires on a healthy server trains people
to ignore timeouts.

---

## 7. Base Role, Not a Base Class

Shared logic lives in `roles/platform/run_state` and the other platform roles, not in a
`cloud_base` role. A `cloud_base` role would create an inheritance relationship between
providers, and provider-specific behaviour would leak through it.

| Shared concern | Where it lives | Why not in the provider role |
|---|---|---|
| Run-state read/write | `roles/platform/run_state` | Identical for all providers; the store is not a cloud concern |
| Tag computation | `roles/platform/naming` + the TagMapper | Cloud-agnostic, driven by capabilities |
| Image selection | `roles/platform/image_resolver` | The catalogue is cloud-agnostic; only the final reference is provider-specific |
| Policy gate | `roles/platform/policy_gate` | Policies are written against the canonical model |
| Retry classification | `roles/platform/*` + [failure-and-retry.md](failure-and-retry.md) | Error codes are canonical, not provider-specific |
| Result artifacts | `roles/platform/report` | Same shape for all providers |
| Idempotency lock | `roles/platform/run_state` | Cross-engine concern |

What remains in the provider role is exactly: the cloud module calls, the capability declaration,
and the immutable/mutable split. That is the part that genuinely differs, and it should be the
only part that does.

---

## 8. Enforcement

`AD-08`'s contract is a convention, so the convention needs a mechanism. Four layers, cheapest
first.

| Layer | Mechanism | Catches |
|---|---|---|
| 1. Static | `ansible-lint` + a custom rule: every role in `roles/cloud/` implements the six task groups | A missing task group |
| 2. CI contract test | For each provider role, a Molecule scenario that exercises the full contract against a mocked API, asserting task names, argument names, and defaults | A signature drift |
| 3. Parity test | The same contract test, run against all three roles with the same inputs and the same assertions | **The signature differences between providers** |
| 4. Review | CODEOWNERS on `roles/cloud/**` | A semantic change to a contract |

The parity test in layer 3 is the one that earns its keep. It is normal for a provider role to
grow a task that makes sense for its cloud; what must not happen is that task becoming
*required*. A parity test with an explicit allow-list catches the accidental case, where an extra
task in one role quietly becomes part of the contract because the playbook started calling it.

**CI enforcement** ([cicd-pipeline.md §2.1 ](cicd-pipeline.md#21-what-each-stage-is-for-and-what-it-cannot-catch)):
a custom check fails the build if a file is added to `roles/cloud/` that does not implement the
contract, and if a task in `roles/cloud/` calls a module outside the allowed cloud namespaces.

---

## 9. Adding a Provider

The checklist, with the honest note about versioning: adding a provider is a **major** version
([cicd-pipeline.md §8 ](cicd-pipeline.md#8-release-management)), because a consumer that assumed
three clouds has to handle four.

1. `configuration/clouds/<name>.yml` — region list, capability declaration, metadata limits
2. `roles/cloud/<name>_vm/` — the six task groups, the capability vars file
3. `roles/image/<name>_image/` — image reference resolution
4. The static dispatch entry in the stage playbooks, plus a `case` branch in the provider
   registry. **No dynamic lookup**
5. A `provider_metadata` key in the schema, validated against the provider's own schema
6. TagMapper support: which canonical keys go to labels vs annotations
7. The contract, parity, and idempotence tests for the new role
8. Error codes for provider-specific transient conditions, with `retryable` set deliberately
9. Update [enterprise-architecture.md](enterprise-architecture.md) and the risk register
10. An `AUTHZ.md` permission review for the new provider's IAM surface

**What must not be added:** a base class, a plugin directory, a dynamic role-name pattern, or a
provider-specific field in the run contract. The contract is engine-neutral and provider-neutral
by `AD-02`; a provider that needs a field the others do not gets it through
`provider_metadata`, which is already schema-validated and already in the run state.

---

## 10. Next

- Per-provider detail: [azure.md](cloud/azure.md), [aws.md](cloud/aws.md), [gcp.md](cloud/gcp.md)
- Role DAG and conventions: [role-dependency-model.md](role-dependency-model.md)
- Naming and tags: [configuration-resolution.md §6 -7](configuration-resolution.md#6-naming-engine)
- Idempotency mechanics: [idempotency.md](idempotency.md)
