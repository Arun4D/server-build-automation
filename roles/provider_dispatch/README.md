# Provider Dispatch Role

## Purpose

The `provider_dispatch` role is the **abstraction seam** for multi-cloud VM provisioning. It routes the `cloud` input variable to the appropriate provider role:

- `gcp` → `cloud_gcp_vm` (fully implemented in Phase 1)
- `azure` → `cloud_azure_vm` (stub with `fail:` task)
- `aws` → `cloud_aws_vm` (stub with `fail:` task)

## Usage

Include this role in your playbook instead of including provider roles directly:

```yaml
- name: Provision VM
  hosts: localhost
  connection: local
  roles:
    - role: provider_dispatch
      vars:
        cloud: gcp
        environment: dev
        os_family: rhel9
        app_tier: web
        vm_count: 3
        requestor: john.doe
        change_ticket: CHG0012345
        expiry_date: "2027-12-31"
```

## Variable Contract

All provider roles (including stubs) accept the **identical 8 input variables**:

| Variable | Type | Required | Description |
|---|---|---|---|
| `cloud` | string | ✅ | `gcp` \| `azure` \| `aws` |
| `environment` | string | ✅ | `dev` \| `staging` \| `prod` |
| `os_family` | string | ✅ | `rhel9` \| `ubuntu2204` \| `windows2022` |
| `app_tier` | string | ✅ | `web` \| `app` \| `db` |
| `vm_count` | integer | ✅ | Number of VMs (1-20) |
| `requestor` | string | ✅ | ServiceNow user |
| `change_ticket` | string | ✅ | ServiceNow CHG number |
| `expiry_date` | string (date) | ❌ | Optional lifecycle expiry |

Plus optional operational variables:
- `sba_operation`: `provision` \| `get` \| `validate` \| `destroy` \| `tag` (default: `provision`)
- `sba_instance_id`: Unique run identifier (UUID, auto-generated if omitted)
- `sba_name`: Short VM name (≤15 chars, auto-generated if omitted)
- `sba_fqdn`: FQDN (auto-generated if omitted)

## Derived Variables

The dispatch role derives all infrastructure coordinates from `group_vars/all/` lookup tables:

- `gcp_project` ← `gcp_project_map[environment]`
- `gcp_region` ← `gcp_region_map[environment][app_tier]`
- `gcp_zone` ← `gcp_zone_map[region].primary`
- `gcp_subnet` ← `gcp_subnet_map[environment][app_tier]`
- `gcp_image_family` ← `gcp_image_family_map[os_family]`
- `gcp_machine_type` ← `gcp_machine_type_map[app_tier][default_size_profile]`
- `gcp_service_account` ← `gcp_service_account_map[environment]`
- `gcp_network` ← `gcp_network_map[environment]`
- Labels/annotations ← `gcp_tag_policy`

## Phase 1 Behavior

| Cloud | Behavior |
|---|---|
| `gcp` | Routes to `cloud_gcp_vm` — full implementation |
| `azure` | Routes to `cloud_azure_vm` — **fails** with "Azure provider not yet enabled in this phase." |
| `aws` | Routes to `cloud_aws_vm` — **fails** with "AWS provider not yet enabled in this phase." |
| Other | **Fails** at validation with "Invalid cloud provider" |

## Adding a New Provider (Phase 2+)

1. Create `roles/cloud_<provider>_vm/` with identical `meta/argument_specs.yml`
2. Implement the 6 task groups per provider contract (lookup, create/adopt, converge, post-provision, decommission, verify)
3. Add lookup tables in `group_vars/all/` (`<provider>_project_map.yml`, etc.)
4. Update `_provider_role_map` in `tasks/main.yml` to include the new provider
5. Add required collections to `collections/requirements.yml`
6. Update `provider_matrix.yml` with new provider entry

## Testing

```bash
# Test GCP path (should succeed)
ansible-playbook -i localhost, playbooks/provision.yml -e cloud=gcp -e environment=dev ...

# Test Azure path (should fail fast with clear message)
ansible-playbook -i localhost, playbooks/provision.yml -e cloud=azure -e environment=dev ...

# Test AWS path (should fail fast with clear message)
ansible-playbook -i localhost, playbooks/provision.yml -e cloud=aws -e environment=dev ...
```