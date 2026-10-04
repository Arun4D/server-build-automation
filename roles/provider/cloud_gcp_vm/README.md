# Cloud GCP VM Role

## Purpose

The `cloud_gcp_vm` role provisions, manages, and destroys Google Cloud Platform Compute Engine instances from golden images. It implements the **unified provider contract** defined in `docs/architecture/provider-abstraction.md` and is invoked via the `provider_dispatch` role.

## Features

- **Create or Adopt** — Idempotent instance creation with atomic label application; adopts existing instances with matching `sba_instance_id` label
- **Immutable Verification** — Asserts project, region, network, subnet, and image cannot differ on adopt
- **Golden Image Resolution** — Resolves image family to pinned self_link at provision time
- **Label/Annotation Management** — Required labels (immutable) + annotations (mutable) per tag policy
- **Shielded VM** — Secure boot, vTPM, integrity monitoring enabled by default
- **OS Login** — Blocks project SSH keys, uses OS Login for access
- **Converge** — Updates mutable attributes (machine type, labels, disk sizes) without recreation
- **Wait for Ready** — Waits for RUNNING state + guest agent (SSH/WinRM)
- **Destroy Safety** — Only deletes instances created by this run (`adopted: false`)
- **Tag Operation** — Updates annotations without reboot

## Variable Contract (8 Input Variables)

All provider roles accept the **identical 8 variables**:

| Variable | Type | Required | Description |
|---|---|---|---|
| `cloud` | string | ✅ | `gcp` (this role only handles gcp) |
| `environment` | string | ✅ | `dev` \| `staging` \| `prod` |
| `os_family` | string | ✅ | `rhel9` \| `ubuntu2204` \| `windows2022` |
| `app_tier` | string | ✅ | `web` \| `app` \| `db` |
| `vm_count` | integer | ✅ | Number of VMs (1-20) |
| `requestor` | string | ✅ | ServiceNow user |
| `change_ticket` | string | ✅ | ServiceNow CHG number |
| `expiry_date` | string (date) | ❌ | Optional lifecycle expiry |

Plus operational variables:
- `sba_operation`: `provision` \| `get` \| `validate` \| `destroy` \| `tag` (default: `provision`)
- `sba_instance_id`: Unique run identifier (UUID, auto-generated if omitted)
- `sba_name`: Short VM name (≤15 chars, auto-generated if omitted)
- `sba_fqdn`: FQDN (auto-generated if omitted)

## Derived Variables (from group_vars/all/)

The `provider_dispatch` role derives all infrastructure coordinates:

| Variable | Source |
|---|---|
| `gcp_project` | `gcp_project_map[environment]` |
| `gcp_region` | `gcp_region_map[environment][app_tier]` |
| `gcp_zone` | `gcp_zone_map[region].primary` |
| `gcp_subnet` | `gcp_subnet_map[environment][app_tier]` |
| `gcp_image_family` | `gcp_image_family_map[os_family]` |
| `gcp_machine_type` | `gcp_machine_type_map[app_tier][default_size_profile]` |
| `gcp_service_account` | `gcp_service_account_map[environment]` |
| `gcp_network` | `gcp_network_map[environment]` |
| Labels/Annotations | `gcp_tag_policy` |

## Operations

### `provision` (default)
Full provisioning workflow:
1. Preflight checks (APIs, quota, subnet, SA, image, machine type)
2. Lookup instance by `sba_instance_id` label
3. Verify immutable attributes match (if adopting)
4. Resolve image family → pinned self_link
5. Create instance with labels applied atomically
6. Attach networking (NIC, subnet, external IP policy)
7. Attach storage (boot disk + optional data disks)
8. Record observed provider IDs (`sba_facts`, `sba_result`)
9. Converge mutable attributes (size, labels, disks)
10. Wait for RUNNING + guest agent
11. Assert postconditions

### `get`
Read-only: lookup instance, read current state, assert postconditions.

### `validate`
Read-only: preflight, lookup, verify immutable, assert postconditions. No create.

### `destroy`
Deletes instance and associated disks (reverse order). **Only if `adopted: false`**.

### `tag`
Updates annotations (mutable) on existing instance. Labels require stop/start (not supported).

## Outputs

### `sba_facts`
```yaml
sba_facts:
  server:
    instance_id: "12345678-1234-1234-1234-123456789012"
    instance_name: "sba-dev-web-r9-001"
    state: "RUNNING"
    private_ip: "10.0.1.5"
    public_ip: ""
    fqdn: "sba-dev-web-r9-001.internal"
    parent_scope: "test-project"
    zone: "us-central1-a"
    region: "us-central1"
    adopted: false
  network:
    vpc_id: "projects/test-project/global/networks/test-vpc"
    subnet_id: "projects/test-project/regions/us-central1/subnetworks/test-subnet"
    nic_id: "nic0"
    private_ip: "10.0.1.5"
    public_ip: ""
    availability_zone: "us-central1-a"
  disk:
    os_disk_id: "sba-dev-web-r9-001"
    os_disk_size_gb: 30
    os_disk_type: "pd-balanced"
    data_disk_ids: []
    data_disk_sizes_gb: []
  image:
    applied_image_id: "projects/.../global/images/rhel-9-gold-v20260901"
    applied_version: "rhel-9-gold-v20260901"
    applied_digest: "projects/.../global/images/rhel-9-gold-v20260901"
  tags:
    applied:
      owner: "test.user"
      cost_center: "CC-DEV-WEB"
      environment: "dev"
      change_ticket: "CHG0000001"
      sba_instance_id: "12345678-1234-1234-1234-123456789012"
    verified: true
```

### `sba_result`
```yaml
sba_result:
  changed: true
  status: "created"
  duration_s: 45.23
  error_code: ""
```

## Required Labels (Immutable)

Applied at create time, cannot be changed without stop/start:
- `owner` → `requestor`
- `cost_center` → derived from `app_tier` + `environment`
- `environment` → `environment`
- `change_ticket` → `change_ticket`
- `expiry` → `expiry_date` (optional)
- `sba_instance_id` → unique run identifier (primary lookup key)

## Annotations (Mutable)

Applied post-create, can be updated anytime:
- `requestor`
- `change_ticket`
- `provisioned_at` (ISO8601 timestamp)
- `provisioned_by` → `sba-automation`
- `sba_run_id` → same as `sba_instance_id`

## Authentication

| Path | Mechanism |
|---|---|
| GitHub Actions | Workload Identity Federation (OIDC) |
| AAP | AAP Credential (GCP Service Account JSON) |
| Local Dev | `gcloud auth application-default login` |

**Never** static JSON keys in repository.

## Testing

### Molecule (Docker Driver - CI)
```bash
cd roles/cloud_gcp_vm
molecule test -s default
```

### Molecule (GCP Driver - Manual Integration)
See `molecule/README.md` for cloud driver configuration. Requires real GCP project.

## Dependencies

Collections (pinned in `collections/requirements.yml`):
- `google.cloud` 1.14.0
- `ansible.utils` 6.1.1
- `community.general` 8.6.0

## Adding a New Provider

See `docs/PLAN.md` §9 "Future Provider Extension Points" and `docs/architecture/provider-abstraction.md`.