# Cloud Azure VM Role - STUB

## Status: Phase 1 Stub (Not Implemented)

This role is a **placeholder** that maintains the unified provider contract interface. The Azure provider is not yet implemented in Phase 1.

## Purpose

- Provides the identical variable interface as `cloud_gcp_vm` so the provider abstraction holds
- Routes via `provider_dispatch` when `cloud: azure`
- Fails fast with a clear message explaining the stub status
- Documents what's needed for future implementation

## Variable Contract (Identical to cloud_gcp_vm)

All provider roles accept the **identical 8 variables**:

| Variable | Type | Required | Description |
|---|---|---|---|
| `cloud` | string | ✅ | `azure` (this role) |
| `environment` | string | ✅ | `dev` \| `staging` \| `prod` |
| `os_family` | string | ✅ | `rhel9` \| `ubuntu2204` \| `windows2022` |
| `app_tier` | string | ✅ | `web` \| `app` \| `db` |
| `vm_count` | integer | ✅ | Number of VMs (1-20) |
| `requestor` | string | ✅ | ServiceNow user |
| `change_ticket` | string | ✅ | ServiceNow CHG number |
| `expiry_date` | string (date) | ❌ | Optional lifecycle expiry |

Plus operational variables:
- `sba_operation`: `provision` \| `get` \| `validate` \| `destroy` \| `tag`
- `sba_instance_id`: Unique run identifier (UUID)
- `sba_name`: Short VM name (≤15 chars)
- `sba_fqdn`: FQDN

## Future Implementation Requirements

To implement Azure provider (Phase 2+):

1. **Replace stub task** with full implementation following provider contract
2. **Implement 6 task groups** per `docs/architecture/provider-abstraction.md`:
   - Lookup (preflight, lookup_instance, verify_immutable)
   - Create/Adopt (resolve_image, create_instance, attach_networking, attach_storage, record_observed)
   - Converge (converge_instance)
   - Post-provision (wait_for_ready)
   - Decommission (list_owned_resources, delete_instance)
   - Verify (assert_instance)

3. **Add Azure lookup tables** in `group_vars/all/`:
   - `azure_subscription_map.yml` (environment → subscription_id)
   - `azure_resource_group_map.yml` (environment → resource_group)
   - `azure_region_map.yml` (environment + app_tier → region)
   - `azure_image_map.yml` (os_family → image reference)
   - `azure_subnet_map.yml` (environment + app_tier → subnet_id)
   - `azure_vm_size_map.yml` (app_tier → VM size)
   - `azure_zone_map.yml` (region → availability zone)
   - `azure_tag_policy.yml` (required tags, naming convention)

4. **Use Azure modules** from `azure.azcollection`:
   - `azure_rm_virtualmachine` for VM management
   - `azure_rm_resource_info` for lookups
   - `azure_rm_image_info` for image resolution
   - `azure_rm_networkinterface` for NIC management
   - `azure_rm_manageddisk` for disk management

5. **Authentication**: Azure Service Principal / Managed Identity / Workload Identity Federation

6. **Update provider_dispatch** (already configured to route 'azure' here)

## Testing

When implemented, add Molecule scenarios:
- `molecule/default/` — Docker driver for logic tests
- `molecule/cloud/` — Azure driver for integration tests

## Provider Contract Reference

- `docs/architecture/provider-abstraction.md` — Role contract, 4 operations
- `docs/architecture/role-dependency-model.md` — Role taxonomy, dependencies
- `docs/PLAN.md` §9 — Future Provider Extension Points