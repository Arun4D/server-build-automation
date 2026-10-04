# Molecule Testing for cloud_gcp_vm

## Overview

This role includes Molecule scenarios for testing:

1. **`molecule/default/`** — Docker driver (fast, runs in CI)
2. **`molecule/cloud/`** — GCP driver (real integration, documented only)

## Default Scenario (Docker Driver)

The default scenario uses the Docker driver for fast logic testing:

- **No real GCP calls** — All GCP modules are mocked
- **Tests role logic** — Variable handling, task flow, idempotency checks
- **Runs in CI** — Fast feedback on every PR
- **Validates outputs** — sba_facts, sba_result, and derived facts

### Running Locally

```bash
cd roles/cloud_gcp_vm
molecule test -s default
```

### What It Tests

- Preflight validation logic
- Instance lookup by label
- Immutable attribute verification
- Image family resolution
- Instance creation/adoption flow
- Networking and storage attachment
- Fact recording (sba_facts, sba_result)
- Converge logic (machine type, labels, disks)
- Wait for ready logic
- Assertion postconditions
- Destroy operation (adopted=false only)
- Tag operation (annotations only)

## Cloud Scenario (GCP Driver) — Documented Only

A `molecule/cloud/` scenario is documented for real GCP integration testing but is **not run in CI** because it requires:

- Real GCP project with billing enabled
- Service account with Compute Admin, Service Account User roles
- VPC, subnets, firewall rules pre-configured
- Golden image families published
- Quota for instances, disks, external IPs

### Cloud Driver Configuration (Reference)

```yaml
# molecule/cloud/molecule.yml
driver:
  name: gcp
  project: "{{ lookup('env', 'GCP_PROJECT') }}"
  zone: "{{ lookup('env', 'GCP_ZONE') }}"
  service_account_file: "{{ lookup('env', 'GOOGLE_APPLICATION_CREDENTIALS') }}"

platforms:
  - name: cloud-gcp-vm-integration
    machine_type: e2-standard-2
    image_family: rhel-9-gold
    network: sba-vpc-dev
    subnetwork: sba-sub-dev-web-us-central1
    service_account: sba-vm-sa@project.iam.gserviceaccount.com
    labels:
      sba_instance_id: "{{ lookup('pipe', 'uuidgen') }}"
      owner: "molecule-test"
      environment: "dev"
      change_ticket: "CHG0000000"
```

### Running Cloud Integration Tests (Manual)

```bash
# Set required environment variables
export GCP_PROJECT="your-test-project"
export GCP_ZONE="us-central1-a"
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/sa-key.json"

# Run cloud scenario
cd roles/cloud_gcp_vm
molecule test -s cloud
```

### When to Run Cloud Tests

- Before major releases
- After GCP module upgrades
- When adding new GCP features
- Periodic validation (monthly)

## Mock Modules

The default scenario uses mock implementations of GCP modules. These are defined in the converge playbook and simulate:

- `gcp_compute_instance` — Returns mock instance with status RUNNING
- `gcp_compute_disk` — Returns mock disk resources
- `gcp_compute_image_info` — Returns mock image family with pinned self_link
- `gcp_compute_machine_type_info` — Returns mock machine type
- `gcp_compute_subnetwork_info` — Returns mock subnet
- `gcp_iam_service_account_info` — Returns mock service account
- `gcp_compute_project_info` — Returns mock project with APIs enabled

## Linting

The scenario includes linting with `ansible-lint --profile production`:

```bash
molecule lint -s default
```

## Troubleshooting

### Docker Driver Issues

- Ensure Docker is running
- Use `molecule destroy -s default` to clean up containers
- Check `molecule/logs/` for detailed output

### Cloud Driver Issues

- Verify GCP credentials and permissions
- Check quota in target region/zone
- Ensure VPC/subnet exist and are accessible
- Verify image family exists in golden images project