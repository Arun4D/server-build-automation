# Architectural Decisions Log — Phase 1: GCP-Only VM Provisioning

**Status:** Living document — updated as decisions are made
**Phase:** 1 (GCP-only)
**Last Updated:** 2026-10-05

---

## Decision Template

Each decision follows this format:

```
### AD-XX: Short Title
**Date:** YYYY-MM-DD
**Status:** Accepted | Superseded | Deferred | Rejected
**Context:** What problem are we solving?
**Decision:** What did we decide?
**Consequences:** Trade-offs, follow-up work, migration path
**Related:** Links to other ADs, docs, issues
```

---

## Decisions

### AD-01: Single Entry Playbooks with Staged Re-entry
**Date:** 2026-10-05
**Status:** Accepted
**Context:** Need a clear, auditable entry point for each operation (provision, domain join, agent install) that can be invoked independently by GitHub Actions, AAP, or ServiceNow.
**Decision:** Three separate playbooks at `playbooks/` root:
- `provision.yml` — creates VMs
- `post_build_domain_join.yml` — joins domain
- `post_build_agent_install.yml` — installs agents
Each targets hosts via dynamic inventory group (`gcp_servers`) or `add_host` from previous run. No monolithic playbook.
**Consequences:** Simpler CI/CD, clearer failure domains, independent retry. Slight duplication of inventory setup.
**Related:** `docs/architecture/logical-architecture.md`, `docs/architecture/request-lifecycle.md`

---

### AD-02: Provider Abstraction via Fixed Contract + Role Allow-List
**Date:** 2026-10-05
**Status:** Accepted
**Context:** Must support GCP now, Azure/AWS later, without refactoring playbooks or roles.
**Decision:** 
- Every provider role implements **identical** task names, parameters, defaults (the "contract")
- Playbook dispatches via `provider_dispatch` role using static `include_role` (no dynamic includes)
- `provider_dispatch` contains a closed map: `gcp → cloud_gcp_vm`, `azure → cloud_azure_vm`, `aws → cloud_aws_vm`
- Any other `cloud` value → explicit `fail:` with clear message
**Consequences:** No dynamic role resolution (security), contract enforced by review + CI check, easy to add providers.
**Related:** `docs/architecture/provider-abstraction.md`, `docs/architecture/role-dependency-model.md`

---

### AD-03: Configuration Resolver is a Python Library, Not Jinja
**Date:** 2026-10-05
**Status:** Accepted
**Context:** Complex lookups (project→region→subnet→image→machine type) with validation, defaults, and error messages.
**Decision:** Resolution logic lives in `scripts/resolve_configuration.py` (invoked by `platform/resolve_configuration` role), not in Jinja templates. Lookup tables in `group_vars/all/` are pure data (YAML/JSON).
**Consequences:** Testable, type-safe, debuggable. Jinja stays simple. Adds Python dependency but only for resolution.
**Related:** `docs/architecture/configuration-resolution.md`

---

### AD-04: ≤ 8 User-Facing Input Variables
**Date:** 2026-10-05
**Status:** Accepted
**Context:** ServiceNow catalog, GitHub Actions forms, AAP surveys must be simple. Operators shouldn't need to know GCP project IDs, subnet names, image self-links.
**Decision:** Exactly 8 variables (see `PLAN.md` §3). Everything else derived from `group_vars/all/` lookup tables keyed by these 8.
**Consequences:** Lookup tables become the "source of truth" for infrastructure coordinates. Must be maintained by platform team. Schema validation at playbook entry.
**Related:** `schemas/gcp-input-vars.schema.json`, `group_vars/all/input_schema.yml`

---

### AD-05: GCP Module Choice — `gcp_compute_instance` Direct (Not Template + MIG)
**Date:** 2026-10-05
**Status:** Accepted
**Context:** For `vm_count` ≤ 10, instance templates + managed instance groups add complexity (template creation, MIG creation, instance recreation on update) with marginal benefit.
**Decision:** Use `google.cloud.gcp_compute_instance` directly in a loop for `vm_count` > 1. Document that for `vm_count` > 20, a future phase may introduce `gcp_compute_instance_template` + `gcp_compute_instance_group_manager`.
**Consequences:** Simpler code, easier debugging, direct idempotency. Less scalable for large fleets (acceptable for Phase 1).
**Related:** `PLAN.md` §4.2, `roles/cloud_gcp_vm/tasks/create_instance.yml`

---

### AD-06: Image Resolution — Image Families (Rolling) with Pinned Recording
**Date:** 2026-10-05
**Status:** Accepted
**Context:** Golden images are published to GCP image families. Using family ref (`projects/.../global/images/family/<family>`) gets latest; using pinned self_link gets exact version.
**Decision:** 
- `gcp_image_family_map[os_family]` stores the **family self_link** (e.g., `projects/sbagoldimages/global/images/family/rhel-9-gold`)
- At provision time (`resolve_image.yml`), resolve family → pinned self_link via `gcp_compute_image_info`
- Record the **pinned self_link** in `sba_facts.image.applied_image_id` for idempotency verification
- Re-run with same family ref will detect drift if family was updated (OS_VERSION_MISMATCH)
**Consequences:** Automatic pickup of new golden images on re-provision; drift detected on converge. Update process: publish new image to family → next provision picks it up.
**Related:** `group_vars/all/gcp_image_family_map.yml`, `roles/cloud_gcp_vm/tasks/resolve_image.yml`

---

### AD-07: Authentication — Workload Identity Federation (GitHub Actions) + AAP Credential (AAP)
**Date:** 2026-10-05
**Status:** Accepted
**Context:** No static credentials in repo. GitHub Actions must auth to GCP; AAP must auth to GCP.
**Decision:**
- **GitHub Actions:** `google-github-actions/auth@v2` with `workload_identity_provider` + `service_account` (OIDC). No JSON keys.
- **AAP:** Credential of type "Google Cloud Service Account" — JSON injected at runtime by AAP. Defined in `automation/aap/credentials/gcp_service_account.yml`.
- **Local dev:** `gcloud auth application-default login` (documented in README, not automated).
**Consequences:** Requires WIF pool/provider setup in GCP (one-time). AAP credential must be created by admin. No secrets in Git.
**Related:** `.github/workflows/provision-gcp.yml`, `automation/aap/credentials/gcp_service_account.yml`

---

### AD-08: Tagging — Labels (Immutable) + Annotations (Mutable) via Shared Role
**Date:** 2026-10-05
**Status:** Accepted
**Context:** GCP labels are immutable without stop/start; annotations are mutable. Need consistent tagging across all resources.
**Decision:** 
- Shared role `roles/common/tagging_gcp` enforces label/annotation policy
- **Labels** (applied at create, immutable): `owner`, `cost_center`, `environment`, `change_ticket`, `expiry`, `sba_instance_id`
- **Annotations** (applied post-create, mutable): `requestor`, `change_ticket`, `provisioned_at`, `provisioned_by`
- `sba_instance_id` is the primary lookup key for idempotency (find instance by label)
**Consequences:** Label changes require VM stop/start (reboot). Documented in role. Annotations used for audit trail.
**Related:** `roles/common/tagging_gcp/`, `group_vars/all/gcp_tag_policy.yml`

---

### AD-09: Post-Build Playbooks Are Independent + Target Dynamic Inventory
**Date:** 2026-10-05
**Status:** Accepted
**Context:** Domain join and agent install may be run by different teams, at different times, or retried independently.
**Decision:** 
- `post_build_domain_join.yml` and `post_build_agent_install.yml` are separate playbooks
- Both target `hosts: gcp_servers` (dynamic inventory group from `google.cloud.gcp_compute_instance` plugin filtered by `sba_instance_id` label)
- Provision playbook adds hosts to `gcp_servers` group via `add_host` for immediate chaining
- Can be invoked independently via GitHub Actions, AAP, or CLI
**Consequences:** Requires dynamic inventory configured in AAP/GH Actions. Slight complexity in inventory setup.
**Related:** `automation/aap/inventories/gcp_dynamic.yml`, `playbooks/post_build_*.yml`

---

### AD-10: Molecule Tests Use Docker Driver (Logic Only); Cloud Driver Documented
**Date:** 2026-10-05
**Status:** Accepted
**Context:** Molecule with GCP driver requires real project, credentials, network — slow and flaky for CI.
**Decision:** 
- `molecule/default/` uses `driver: docker` for logic tests (task syntax, variable handling, idempotency checks with mocked modules)
- Document `molecule/cloud/` scenario using `driver: gcp` for real integration tests (run manually/periodically)
- CI runs docker driver only; cloud driver is opt-in
**Consequences:** Fast CI feedback. Real cloud bugs caught in periodic integration runs, not every PR.
**Related:** `roles/cloud_gcp_vm/molecule/default/molecule.yml`, `roles/cloud_gcp_vm/molecule/README.md`

---

### AD-11: Stub Roles for Azure/AWS — Identical Interface, `fail:` Task
**Date:** 2026-10-05
**Status:** Accepted
**Context:** Phase 1 is GCP-only. Azure/AWS must not block GCP work but must not require refactoring later.
**Decision:** 
- Create `roles/cloud_azure_vm/` and `roles/cloud_aws_vm/` with:
  - `tasks/main.yml`: single `fail:` task with message "X provider not yet enabled in this phase."
  - `defaults/main.yml`: same variable defaults as `cloud_gcp_vm`
  - `meta/argument_specs.yml`: **identical** to `cloud_gcp_vm`
  - `README.md`: stub notice
- `provider_dispatch` routes `azure`/`aws` to these stubs (which fail fast)
**Consequences:** Abstraction seam validated now. Future phase replaces stub with implementation — no playbook changes.
**Related:** `roles/provider_dispatch/tasks/main.yml`, `PLAN.md` §9

---

### AD-12: Post-Build Stubs — `fail:` with Explicit TODO List
**Date:** 2026-10-05
**Status:** Accepted
**Context:** Domain join and agent install tooling not yet decided. Must not block provision work.
**Decision:** 
- `roles/postbuild_domain_join/tasks/main.yml`: `fail:` with TODO list (domain, OU, creds, OS support, verification)
- `roles/postbuild_agent_install/tasks/main.yml`: `fail:` with TODO list (agent choice, install method, config source, verification)
- Both have `argument_specs.yml` defining their inputs (instance_id + domain/agent params)
**Consequences:** Clear decision tracking. Playbooks exist and can be wired; implementation fills in when decisions made.
**Related:** `PLAN.md` §5, `docs/open-questions.md`

---

### AD-13: ServiceNow Contract — Payload Maps 1:1 to 8 Vars + Callback
**Date:** 2026-10-05
**Status:** Accepted
**Context:** ServiceNow Flow Designer / IntegrationHub needs a stable contract to trigger provisioning.
**Decision:** 
- **Request payload:** 8 input variables + optional `callback_url`
- **Auth:** GitHub App token (for `repository_dispatch` to `.github/workflows/provision-gcp-dispatch.yml`) OR AAP token (for AAP Job Template launch API)
- **Response:** JSON callback to `callback_url` with `{ instance_id, status, private_ip, fqdn, error_code? }`
- Documented in `docs/servicenow_contract.md` with JSONSchema
**Consequences:** ServiceNow team can build integration in parallel. Callback enables async tracking.
**Related:** `docs/servicenow_contract.md`, `.github/workflows/provision-gcp-dispatch.yml`

---

### AD-14: No Secrets in Repository — Placeholders Only
**Date:** 2026-10-05
**Status:** Accepted
**Context:** Security policy. Examples/docs must not contain real project IDs, service account emails, keys.
**Decision:** All examples use placeholders: `<gcp-project-id>`, `<service-account@project.iam.gserviceaccount.com>`, `<workload-identity-pool>`. Real values injected at runtime via:
- GitHub Actions: OIDC (no secret)
- AAP: Credential (secret stored in AAP, not repo)
- Local: `gcloud` ADC (user's local config)
**Consequences:** Safe to commit. CI can validate syntax without secrets.
**Related:** `ansible.cfg` (vault_password_file outside repo), `.github/workflows/provision-gcp.yml`

---

### AD-15: `sba_instance_id` as Primary Lookup Key (Not Name)
**Date:** 2026-10-05
**Status:** Accepted
**Context:** VM names can collide, be reused, or change. Need a stable, unique identifier for idempotency.
**Decision:** 
- `sba_instance_id` is a UUID (or ServiceNow sys_id) generated at request intake
- Applied as **label** on GCP instance (immutable without stop/start)
- All lookups (`lookup_instance.yml`, `list_owned_resources.yml`) filter by this label
- Name (`sba_name`) is derived for display/hostname but not used for identity
**Consequences:** Requires `sba_instance_id` generation at intake (platform/resolve stage). Label is the source of truth.
**Related:** `roles/cloud_gcp_vm/tasks/lookup_instance.yml`, `platform/naming` role

---

### AD-16: `provider_dispatch` Lives in `roles/` (Not `roles/platform/`)
**Date:** 2026-10-05
**Status:** Accepted
**Context:** Where does the dispatch role belong in the taxonomy?
**Decision:** `roles/provider_dispatch/` (top-level under `roles/`). It's a **dispatcher**, not a platform utility. It knows about provider roles (C family) but doesn't mutate cloud state itself.
**Consequences:** Clear separation: `platform/` = controller-side utilities; `provider_dispatch` = abstraction seam.
**Related:** `docs/architecture/role-dependency-model.md` §1 (Taxonomy)

---

### AD-17: New `cloud_gcp_vm` Role Distinct from Existing `provider/gcp_compute`
**Date:** 2026-10-05
**Status:** Accepted
**Context:** Existing `provider/gcp_compute` uses `sba_` prefixed variables and a different contract (operations: provision/get/validate/destroy/tag via `sba_operation`).
**Decision:** Create new `roles/cloud_gcp_vm/` implementing the **unified 8-variable interface** specified in this phase. The existing `provider/gcp_compute` is deprecated for new work but kept for reference/legacy.
**Consequences:** Two GCP roles coexist temporarily. Migration path: new playbooks use `cloud_gcp_vm`; old playbooks use `provider/gcp_compute`. No breaking changes to existing automation.
**Related:** `PHASE_TREE.md`, `provider_matrix.yml` (updated to reference `cloud_gcp_vm`)

---

### AD-18: Lookup Tables in `group_vars/all/` (Not in Role Defaults)
**Date:** 2026-10-05
**Status:** Accepted
**Context:** Infrastructure coordinates (project, region, subnet, image, machine type) vary by environment, app_tier, os_family. Hardcoding in role defaults is anti-pattern.
**Decision:** All lookup tables in `group_vars/all/`:
- `gcp_project_map.yml`
- `gcp_region_map.yml`
- `gcp_image_family_map.yml`
- `gcp_subnet_map.yml`
- `gcp_machine_type_map.yml`
- `gcp_zone_map.yml`
- `gcp_tag_policy.yml`
Role reads via `include_vars` or `hostvars['localhost']`. Single source of truth, reviewable in Git.
**Consequences:** Role is portable across environments. Changes to infrastructure coordinates are Git-tracked, reviewable.
**Related:** `group_vars/all/`, `PLAN.md` §3

---

### AD-19: JSONSchema Validation at Playbook Entry
**Date:** 2026-10-05
**Status:** Accepted
**Context:** Fail fast on invalid input (wrong enum, missing required, type mismatch) before any cloud API calls.
**Decision:** 
- `schemas/gcp-input-vars.schema.json` defines the 8-variable contract
- `playbooks/provision.yml` (and post-build) validate input via `ansible.builtin.assert` + `jsonschema` filter (or custom validation task) at start
- Same schema used by GitHub Actions (input validation), AAP (survey spec), ServiceNow (payload validation)
**Consequences:** Single source of truth for input contract. Early failure with clear message.
**Related:** `schemas/gcp-input-vars.schema.json`, `group_vars/all/input_schema.yml`

---

### AD-20: Lint Gates — `ansible-lint --profile production` + `yamllint` + `gitleaks` + `checkov`
**Date:** 2026-10-05
**Status:** Accepted
**Context:** Enforce quality, security, and consistency automatically.
**Decision:** CI pipeline runs all four. Configuration files committed:
- `.ansible-lint` (production profile)
- `.yamllint.yml`
- `.gitleaks.toml`
- `checkov` uses built-in Ansible rules
**Consequences:** PRs blocked on lint failures. Requires initial cleanup of existing codebase.
**Related:** `Makefile` (lint targets), CI config (to be added)

---

## Deferred / Open Decisions

| ID | Question | Status | Target Resolution |
|---|---|---|---|
| Q1 | Instance template + MIG for `vm_count` > 1? | Deferred | Phase 2 or when `vm_count` > 20 |
| Q2 | Exact `sba_name` naming convention (≤15, lowercase, unique) | Open | Before `cloud_gcp_vm` create_instance task |
| Q3 | `sba_instance_id` generation algorithm | Open | Before `platform/naming` role |
| Q4 | Image family vs pinned image in `gcp_image_family_map` | Open | Before `group_vars/all/gcp_image_family_map.yml` |
| Q5 | `cost_center` derivation logic | Open | Before `gcp_tag_policy.yml` |
| Q6 | Domain join tooling (realm/sssd vs adcli vs PowerShell) | Open | Before `postbuild_domain_join` implementation |
| Q7 | Agent choice (Dynatrace/Datadog/CrowdStrike/other) | Open | Before `postbuild_agent_install` implementation |
| Q8 | Auto-decommission on `expiry_date` (Cloud Scheduler + Function) | Deferred | Phase 2 |
| Q9 | Windows on GCP specifics (WinRM, gcloud agent, OS Login) | Deferred | When `os_family=windows2022` is needed |
| Q10 | `provider_dispatch` location finalization | Accepted (AD-16) | — |

---

## Superseded Decisions

*None yet — this is Phase 1 initialization.*

---

## Decision Index by Topic

| Topic | Decisions |
|---|---|
| Playbook Structure | AD-01, AD-09 |
| Provider Abstraction | AD-02, AD-11, AD-16, AD-17 |
| Configuration/Resolution | AD-03, AD-04, AD-18, AD-19 |
| GCP Implementation | AD-05, AD-06, AD-07, AD-08, AD-15 |
| Testing | AD-10 |
| Security/Secrets | AD-07, AD-14 |
| Stubs/Placeholders | AD-11, AD-12 |
| Integrations | AD-13 |
| Quality Gates | AD-20 |

---

## How to Add a Decision

1. Assign next AD number (AD-21, AD-22, ...)
2. Use the template above
3. Add to "Decisions" section
4. Update "Decision Index by Topic"
5. Reference in related files (PLAN.md, code comments, PR description)
6. If superseding, mark old decision as "Superseded" and link to new one