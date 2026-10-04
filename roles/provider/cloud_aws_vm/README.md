# Cloud AWS VM Role - STUB

## Status: Phase 1 Stub (Not Implemented)

This role is a **placeholder** that maintains the unified provider contract interface. The AWS provider is not yet implemented in Phase 1.

## Purpose

- Provides the identical variable interface as `cloud_gcp_vm` so the provider abstraction holds
- Routes via `provider_dispatch` when `cloud: aws`
- Fails fast with a clear message explaining the stub status
- Documents what's needed for future implementation

## Variable Contract (Identical to cloud_gcp_vm)

All provider roles accept the **identical 8 variables**:

| Variable | Type | Required | Description |
|---|---|---|---|
| `cloud` | string | ✅ | `aws` (this role) |
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

To implement AWS provider (Phase 2+):

1. **Replace stub task** with full implementation following provider contract
2. **Implement 6 task groups** per `docs/architecture/provider-abstraction.md`:
   - Lookup (preflight, lookup_instance, verify_immutable)
   - Create/Adopt (resolve_image, create_instance, attach_networking, attach_storage, record_observed)
   - Converge (converge_instance)
   - Post-provision (wait_for_ready)
   - Decommission (list_owned_resources, delete_instance)
   - Verify (assert_instance)

3. **Add AWS lookup tables** in `group_vars/all/`:
   - `aws_account_map.yml` (environment → account_id)
   - `aws_region_map.yml` (environment + app_tier → region)
   - `aws_image_map.yml` (os_family → AMI ID)
   - `aws_subnet_map.yml` (environment + app_tier → subnet_id)
   - `aws_instance_type_map.yml` (app_tier → instance type)
   - `aws_az_map.yml` (region → availability zone)
   - `aws_tag_policy.yml` (required tags, naming convention)
   - `aws_security_group_map.yml` (environment + app_tier → SG IDs)

4. **Use AWS modules** from `amazon.aws`:
   - `ec2_instance` for VM management
   - `ec2_instance_info` for lookups
   - `ec2_ami_info` for image resolution
   - `ec2_vpc_subnet_info` for subnet lookups
   - `ec2_vol` for EBS volume management
   - `ec2_security_group` for SG management

5. **Authentication**: IAM Role / Access Keys / Workload Identity Federation

6. **Update provider_dispatch** (already configured to route 'aws' here)

## Testing

When implemented, add Molecule scenarios:
- `molecule/default/` — Docker driver for logic tests
- `molecule/cloud/` — AWS driver for integration tests

## Provider Contract Reference

- `docs/architecture/provider-abstraction.md` — Role contract, 4 operations
- `docs/architecture/role-dependency-model.md` — Role taxonomy, dependencies
- `docs/PLAN.md` §9 — Future Provider Extension Points