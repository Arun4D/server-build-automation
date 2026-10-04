# Project Plan — Phase 1: GCP-Only VM Provisioning

**Status:** In Progress
**Phase:** 1 of N (GCP-only implementation)
**Date:** 2026-10-05
**Scope:** Multi-cloud Ansible VM provisioning — GCP fully implemented; Azure/AWS as interface stubs only

---

## 1. Phase Objective

Deliver a production-ready GCP VM provisioning pipeline with:
- ≤ 8 user-facing input variables
- All infrastructure coordinates derived from lookup tables (`group_vars/all/`)
- Clean provider abstraction via `provider_dispatch` role
- GitHub Actions (OIDC) and AAP invocation paths
- ServiceNow trigger contract
- Post-build playbooks (domain join, agent install) as independent, invokable units
- Molecule tests, lint gates, documentation

**Out of scope for this phase:** Working Azure/AWS implementations. They exist only as `fail:` stubs with identical variable interfaces so the abstraction holds for future phases.

---

## 2. Deliverables Checklist

| # | Deliverable | Status | Notes |
|---|---|---|---|
| 1 | Final directory tree (`docs/PHASE_TREE.md`) | ✅ Done | |
| 2 | `docs/PLAN.md` (this file) | 🟢 In Progress | |
| 3 | `docs/DECISIONS.md` | ⏳ Pending | |
| 4 | `collections/requirements.yml` + `ansible.cfg` | ⏳ Pending | Pin google.cloud 1.14.0, community.general 8.6.0, ansible.posix 1.5.4, ansible.utils 6.1.1 |
| 5 | `group_vars/all/` — input schema + 7 GCP lookup tables | ⏳ Pending | |
| 6 | `roles/provider_dispatch/` | ⏳ Pending | Routes `cloud=gcp` → `cloud_gcp_vm`; fails for others |
| 7 | `roles/cloud_gcp_vm/` (full implementation) | ⏳ Pending | 12 task files, molecule, argument_specs |
| 8 | `roles/cloud_azure_vm/` (stub) | ⏳ Pending | `fail:` + identical interface |
| 9 | `roles/cloud_aws_vm/` (stub) | ⏳ Pending | `fail:` + identical interface |
| 10 | `roles/common/tagging_gcp/` | ⏳ Pending | Shared label/annotation enforcement |
| 11 | `roles/postbuild_domain_join/` (stub) | ⏳ Pending | `fail:` + TODO list |
| 12 | `roles/postbuild_agent_install/` (stub) | ⏳ Pending | `fail:` + TODO list |
| 13 | `playbooks/provision.yml` | ⏳ Pending | GCP entry point via provider_dispatch |
| 14 | `playbooks/post_build_domain_join.yml` | ⏳ Pending | Targets dynamic inventory group |
| 15 | `playbooks/post_build_agent_install.yml` | ⏳ Pending | Targets dynamic inventory group |
| 16 | `.github/workflows/provision-gcp.yml` | ⏳ Pending | Reusable, OIDC, workflow_dispatch + repository_dispatch |
| 17 | `.github/workflows/provision-gcp-dispatch.yml` | ⏳ Pending | ServiceNow payload wrapper |
| 18 | `automation/aap/` — credentials, inventories, job templates, workflow templates | ⏳ Pending | Survey limited to 8 vars |
| 19 | `docs/servicenow_contract.md` | ⏳ Pending | Payload, mapping, auth, response format |
| 20 | `README.md` with mermaid diagrams | ⏳ Pending | Architecture + sequence diagrams |
| 21 | `schemas/gcp-input-vars.schema.json` | ⏳ Pending | JSONSchema for 8 input variables |

---

## 3. Input Variable Contract (≤ 8 Variables)

All provider roles (`cloud_gcp_vm`, `cloud_azure_vm`, `cloud_aws_vm`) accept **identical** inputs:

| Variable | Type | Required | Description | Example |
|---|---|---|---|---|
| `cloud` | string | ✅ | Target cloud provider | `gcp` \| `azure` \| `aws` |
| `environment` | string | ✅ | Deployment environment | `dev` \| `staging` \| `prod` |
| `os_family` | string | ✅ | OS family/version | `rhel9` \| `ubuntu2204` \| `windows2022` |
| `app_tier` | string | ✅ | Application tier | `web` \| `app` \| `db` |
| `vm_count` | integer | ✅ | Number of VMs to provision | `3` |
| `requestor` | string | ✅ | ServiceNow user who requested | `john.doe` |
| `change_ticket` | string | ✅ | ServiceNow change ticket number | `CHG0012345` |
| `expiry_date` | string (date) | ❌ | Optional lifecycle expiry | `2027-12-31` |

**Everything else is derived** from `group_vars/all/` lookup tables:
- `gcp_project_map[environment]` → project_id
- `gcp_region_map[environment][app_tier]` → region
- `gcp_image_family_map[os_family]` → image family self_link
- `gcp_subnet_map[environment][app_tier]` → subnet self_link
- `gcp_machine_type_map[app_tier]` → machine type
- `gcp_zone_map[region]` → preferred zone
- `gcp_tag_policy` → required labels/annotations, naming convention

---

## 4. GCP Implementation Details

### 4.1 Collections (pinned in `collections/requirements.yml`)
- `google.cloud` 1.14.0
- `community.general` 8.6.0
- `ansible.posix` 1.5.4
- `ansible.utils` 6.1.1

### 4.2 Core Module Choice
**Decision:** Use `google.cloud.gcp_compute_instance` directly (not instance template + group manager).
**Rationale:** Simpler for single-VM and small-count provisioning; instance templates add complexity for marginal benefit when `vm_count` ≤ 10. Documented in `DECISIONS.md`.

### 4.3 Image Resolution
```yaml
# group_vars/all/gcp_image_family_map.yml
rhel9: "projects/sbagoldimages/global/images/family/rhel-9-gold"
ubuntu2204: "projects/sbagoldimages/global/images/family/ubuntu-2204-lts-gold"
windows2022: "projects/sbagoldimages/global/images/family/windows-2022-gold"
```
Resolved in `resolve_image.yml` task to a pinned self_link at provision time.

### 4.4 Networking
Subnet from `gcp_subnet_map[environment][app_tier]` → full self_link.
No hardcoded project IDs — all derived from `gcp_project_map[environment]`.

### 4.5 Authentication
| Path | Mechanism |
|---|---|
| GitHub Actions | Workload Identity Federation (OIDC) → GCP Service Account |
| AAP | AAP Credential (GCP Service Account JSON) injected at runtime |
| Local dev | `gcloud auth application-default login` (documented, not in repo) |

**Never** static JSON keys in repository.

### 4.6 Tagging/Labels (via `roles/common/tagging_gcp`)
Required labels (enforced at create time, immutable without stop/start):
- `owner` → `requestor`
- `cost_center` → derived from `app_tier` + `environment`
- `environment` → `environment`
- `change_ticket` → `change_ticket`
- `expiry` → `expiry_date` (if provided)
- `sba_instance_id` → unique run identifier (primary lookup key)

Annotations (mutable, applied post-create):
- `requestor`, `change_ticket`, `provisioned_at`, `provisioned_by`

### 4.7 Idempotency
- `state: present` on all `gcp_compute_instance` tasks
- Register outputs, guard with `when:` conditions
- `lookup_instance.yml` finds by `sba_instance_id` label
- `verify_immutable.yml` asserts project/region/network/image match
- `converge_instance.yml` updates only mutable attributes (size, labels, disks)

---

## 5. Post-Build Playbooks (GCP Path Only)

### 5.1 `post_build_domain_join.yml`
- **Target:** Hosts in `gcp_servers` dynamic inventory group (or `add_host` from provision run)
- **Stub implementation:** `roles/postbuild_domain_join/tasks/main.yml` contains `fail:` with TODO:
  - [ ] Domain controller FQDN / realm
  - [ ] OU placement strategy (per environment? per app_tier?)
  - [ ] Credentials source (AAP credential? Vault? CyberArk?)
  - [ ] OS support matrix (RHEL 9 via `realm`/`sssd`; Ubuntu 22.04; Windows 2022)
  - [ ] Idempotent re-join logic (detect existing join, handle computer object cleanup)
  - [ ] Verification: `realm list` / `klist` / AD computer object exists

### 5.2 `post_build_agent_install.yml`
- **Target:** Same as domain join
- **Stub implementation:** `roles/postbuild_agent_install/tasks/main.yml` contains `fail:` with TODO:
  - [ ] Agent selection: Dynatrace vs Datadog vs CrowdStrike vs other
  - [ ] Installation method: package (rpm/deb/msi) vs script vs container
  - [ ] Configuration source: AAP survey? Vault? Parameter store?
  - [ ] Policy/tenant assignment per environment
  - [ ] Connectivity verification (heartbeat, test metric, first scan)
  - [ ] Upgrade/rotation strategy

**Both playbooks are independent** — can be run separately, in any order, after provision completes.

---

## 6. Trigger Contracts

### 6.1 GitHub Actions
- **Reusable workflow:** `.github/workflows/provision-gcp.yml`
  - `workflow_dispatch` (manual) + `repository_dispatch` (ServiceNow)
  - Inputs: the 8 variables above
  - OIDC: `google-github-actions/auth@v2` with `workload_identity_provider` + `service_account`
  - Runs `ansible-playbook playbooks/provision.yml`
- **Dispatch wrapper:** `.github/workflows/provision-gcp-dispatch.yml`
  - Accepts ServiceNow payload, maps to 8 vars, calls reusable workflow

### 6.2 AAP (Ansible Automation Platform)
- **Credential:** `automation/aap/credentials/gcp_service_account.yml` — GCP Service Account type
- **Dynamic Inventory:** `automation/aap/inventories/gcp_dynamic.yml` — `google.cloud.gcp_compute_instance` plugin
- **Job Templates** (survey = 8 vars):
  - `provision_gcp.yml` → `playbooks/provision.yml`
  - `post_build_domain_join.yml` → `playbooks/post_build_domain_join.yml` (+ domain params)
  - `post_build_agent_install.yml` → `playbooks/post_build_agent_install.yml` (+ agent params)
- **Workflow Template:** `full_build_gcp.yml` — chains all three

### 6.3 ServiceNow
Documented in `docs/servicenow_contract.md`:
- **Payload fields:** Maps 1:1 to 8 input variables + optional `callback_url`
- **Auth:** GitHub App token (for `repository_dispatch`) OR AAP token (for AAP API)
- **Response:** JSON callback with `instance_id`, `status`, `private_ip`, `fqdn`, `error_code?`

---

## 7. Quality Gates

| Tool | Config | Gate |
|---|---|---|
| `ansible-lint` | `--profile production` | Must pass in CI |
| `yamllint` | `.yamllint.yml` | Must pass in CI |
| `gitleaks` | `.gitleaks.toml` | Must pass in CI |
| `checkov` | Ansible rules | Must pass in CI |
| Molecule | `molecule/default/` (docker driver) | `cloud_gcp_vm` scenario passes |
| Schema validation | `schemas/gcp-input-vars.schema.json` | Input validated at playbook entry |

---

## 8. Open Questions (Track in `docs/DECISIONS.md`)

| ID | Question | Status | Owner |
|---|---|---|---|
| Q1 | Should `vm_count` > 1 use instance template + managed instance group, or loop `gcp_compute_instance`? | Open | |
| Q2 | What is the exact naming convention for `sba_name`? (≤15 chars, lowercase, unique per run) | Open | |
| Q3 | How is `sba_instance_id` generated? (UUID? timestamp+random? ServiceNow sys_id?) | Open | |
| Q4 | Should `gcp_image_family_map` point to image families (rolling) or pinned images (immutable)? | Open | |
| Q5 | What is the `cost_center` derivation logic from `app_tier` + `environment`? | Open | |
| Q6 | Domain join: which tool? `realm`/`sssd` (RHEL), `adcli` (Ubuntu), PowerShell (Windows)? | Open | |
| Q7 | Agent choice: Dynatrace, Datadog, CrowdStrike, or other? | Open | |
| Q8 | Should `expiry_date` trigger automatic decommission (Cloud Scheduler + Cloud Function)? | Open | |
| Q9 | How to handle Windows VMs on GCP (WinRM, gcloud guest agent, OS Login)? | Open | |
| Q10 | Should `provider_dispatch` live in `roles/` or `roles/platform/`? | Open | |

---

## 9. Future Provider Extension Points (Phase 2+)

> **No directories created in this phase.** Documented here so future implementers know the pattern.

To add a new provider (e.g., OCI, vSphere, IBM Cloud, Alibaba Cloud):

1. **Create role:** `roles/cloud_<provider>_vm/` with identical `meta/argument_specs.yml` to `cloud_gcp_vm`
2. **Implement 6 task groups** per provider contract (lookup, create/adopt, converge, post-provision, decommission, verify)
3. **Add lookup tables** in `group_vars/all/`:
   - `<provider>_project_map.yml` (or account/subscription/tenant equivalent)
   - `<provider>_region_map.yml`
   - `<provider>_image_map.yml` (or image_family_map)
   - `<provider>_subnet_map.yml` (or vnet/subnet equivalent)
   - `<provider>_size_map.yml` (machine type / instance type / flavor)
   - `<provider>_zone_map.yml` (availability zone / zone equivalent)
   - `<provider>_tag_policy.yml`
4. **Update `provider_dispatch`** to route `cloud=<provider>` → `cloud_<provider>_vm`
5. **Add collections** to `collections/requirements.yml`
6. **Add GitHub Actions workflow** (`.github/workflows/provision-<provider>.yml`) with provider auth
7. **Add AAP job templates** with provider credential
8. **Update `provider_matrix.yml`** with new provider entry
9. **Document** in `docs/architecture/provider-abstraction.md` and `docs/PLAN.md`

**Provider Contract Reference:** `docs/architecture/provider-abstraction.md` §2 (Role Contract) and §3 (Four Operations).

---

## 10. Timeline / Milestones

| Milestone | Target | Dependencies |
|---|---|---|
| Directory tree + PLAN + DECISIONS | Day 1 | — |
| Collections + ansible.cfg + group_vars | Day 2 | PLAN |
| provider_dispatch + cloud_gcp_vm (core tasks) | Day 3-4 | group_vars |
| cloud_gcp_vm (converge, wait, verify, molecule) | Day 5 | core tasks |
| Stubs (azure, aws, postbuild) | Day 5 | argument_specs |
| Playbooks (provision, post-build) | Day 6 | roles |
| GitHub Actions + AAP templates | Day 7 | playbooks |
| servicenow_contract + README + schemas | Day 7-8 | all above |
| Lint gates + CI integration | Day 8 | all code |
| **Phase 1 Complete** | **Day 8-9** | — |

---

## 11. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| GCP API quotas block provisioning | Medium | High | Preflight checks quota; document quota increase process |
| Image family resolution returns unexpected version | Low | High | Pin to specific image in `gcp_image_family_map`; document update process |
| Workload Identity Federation misconfiguration | Medium | High | Test OIDC flow in dedicated GH Actions environment; document troubleshooting |
| Molecule docker driver doesn't catch cloud-specific bugs | Medium | Medium | Document cloud-driver option; run integration tests in real GCP project periodically |
| Variable interface drift between provider roles | Low | High | Shared `argument_specs.yml` template; CI check for identical specs |

---

## 12. Success Criteria

- [ ] `ansible-playbook playbooks/provision.yml` provisions a GCP VM from golden image with ≤8 input vars
- [ ] All infrastructure coordinates derived from `group_vars/all/` (no hardcoded values in role)
- [ ] `provider_dispatch` routes `cloud=gcp` correctly; fails fast for `azure`/`aws` with clear message
- [ ] GitHub Actions workflow runs via OIDC, no secrets in repo
- [ ] AAP job template survey accepts only the 8 vars; deploys via credential
- [ ] Post-build playbooks run independently against dynamic inventory
- [ ] `ansible-lint --profile production`, `yamllint`, `gitleaks`, `checkov` all pass
- [ ] Molecule scenario for `cloud_gcp_vm` passes (docker driver)
- [ ] `docs/PLAN.md`, `DECISIONS.md`, `servicenow_contract.md`, `README.md` complete
- [ ] ServiceNow payload contract documented and validated against schema