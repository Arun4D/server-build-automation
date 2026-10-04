# Phase 1 Directory Tree — GCP-Only Implementation

**Legend:**
- `[IMPL]` — Fully implement in this phase
- `[STUB]` — Create directory + `fail:` task + interface stubs (same variable interface)
- `[PLACEHOLDER]` — Document extension point only, no directory created
- `[DOC]` — Documentation only
- `[EXISTING]` — Already exists, may need updates

---

## Root Level

```
server-build-automation/
├── ansible.cfg                          [EXISTING] — update collections_path for new roles
├── collections/requirements.yml         [IMPL] — pin google.cloud, community.general, ansible.posix, ansible.utils
├── Makefile                             [EXISTING] — add targets for new playbooks
├── PROJECT_BOOTSTRAP.md                 [EXISTING]
├── README.md                            [IMPL] — rewrite with mermaid architecture + sequence diagrams
├── requirements-dev.txt                 [EXISTING]
├── requirements.yml                     [EXISTING] — keep for Galaxy install
└── execution-environment.yml            [EXISTING]
```

---

## Configuration Layer

```
configuration/
├── README.md                            [EXISTING]
├── applications/                        [EXISTING]
├── clouds/
│   ├── gcp.yml                          [EXISTING] — verify/extend for image families, subnets, machine types
│   ├── azure.yml                        [EXISTING] — keep as placeholder config
│   ├── aws.yml                          [EXISTING] — keep as placeholder config
│   ├── hybridcloud.yml                  [EXISTING]
│   ├── hyperv.yml                       [EXISTING]
│   ├── nutanix.yml                      [EXISTING]
│   └── vmware.yml                       [EXISTING]
├── environments/                        [EXISTING]
├── images/
│   └── linux_images.yml                 [EXISTING] — verify GCP image family refs
├── os/
│   └── linux.yml                        [EXISTING]
├── policies/                            [EXISTING]
├── regions/                             [EXISTING]
├── routing/
│   └── provider_matrix.yml              [IMPL] — update to reference new cloud_gcp_vm role
└── server_roles/                        [EXISTING]
```

---

## Group Vars (NEW — critical for ≤8 var interface)

```
group_vars/
└── all/
    ├── input_schema.yml                 [IMPL] — JSONSchema for the 8 input vars + validation
    ├── gcp_project_map.yml              [IMPL] — environment → project_id
    ├── gcp_region_map.yml               [IMPL] — environment/app_tier → region
    ├── gcp_image_family_map.yml         [IMPL] — os_family → image family self_link
    ├── gcp_subnet_map.yml               [IMPL] — environment/app_tier → subnet self_link
    ├── gcp_machine_type_map.yml         [IMPL] — app_tier/size → machine type
    ├── gcp_tag_policy.yml               [IMPL] — required labels/annotations, naming convention
    └── gcp_zone_map.yml                 [IMPL] — region → preferred zone
```

---

## Roles — Provider Abstraction Layer

```
roles/
├── provider_dispatch/                   [IMPL] — routes cloud=gcp → cloud_gcp_vm; fails for others
│   ├── tasks/
│   │   └── main.yml
│   ├── defaults/
│   │   └── main.yml
│   ├── meta/
│   │   └── argument_specs.yml
│   └── README.md
│
├── cloud_gcp_vm/                        [IMPL] — full GCP implementation (NEW role, distinct from provider/gcp_compute)
│   ├── tasks/
│   │   ├── main.yml                     # dispatch on sba_operation
│   │   ├── preflight.yml                # validate project, quota, APIs enabled
│   │   ├── lookup_instance.yml          # find by sba_instance_id label
│   │   ├── verify_immutable.yml         # assert project/region/network/image match
│   │   ├── resolve_image.yml            # map image_family_map[os_family] → self_link
│   │   ├── create_instance.yml          # gcp_compute_instance with labels atomic
│   │   ├── attach_networking.yml        # NIC, subnet, external IP policy
│   │   ├── attach_storage.yml           # boot disk from image, data disks
│   │   ├── record_observed.yml          # write provider IDs to sba_facts
│   │   ├── converge_instance.yml        # resize, relabel, re-encrypt (mutable only)
│   │   ├── wait_for_ready.yml           # instance RUNNING + guest agent
│   │   ├── list_owned_resources.yml     # all resources with sba_instance_id label
│   │   ├── delete_instance.yml          # reverse order, only adopted=false
│   │   └── assert_instance.yml          # postconditions
│   ├── defaults/
│   │   └── main.yml                     # shared defaults (retry, timeouts)
│   ├── vars/
│   │   └── main.yml                     # internal constants
│   ├── meta/
│   │   ├── argument_specs.yml           # full argument spec for 8 vars + derived
│   │   └── main.yml
│   ├── handlers/
│   │   └── main.yml
│   ├── library/                         # custom modules if needed
│   ├── molecule/
│   │   └── default/
│   │       ├── molecule.yml             # docker driver for logic tests
│   │       ├── converge.yml
│   │       ├── verify.yml
│   │       └── README.md                # documents cloud-driver option for real integration
│   └── README.md
│
├── cloud_azure_vm/                      [STUB] — placeholder with fail task
│   ├── tasks/
│   │   └── main.yml                     # single fail: "Azure provider not yet enabled in this phase."
│   ├── defaults/
│   │   └── main.yml                     # same variable interface as cloud_gcp_vm
│   ├── meta/
│   │   ├── argument_specs.yml           # identical to cloud_gcp_vm
│   │   └── main.yml
│   └── README.md                        # stub notice
│
├── cloud_aws_vm/                        [STUB] — placeholder with fail task
│   ├── tasks/
│   │   └── main.yml                     # single fail: "AWS provider not yet enabled in this phase."
│   ├── defaults/
│   │   └── main.yml                     # same variable interface as cloud_gcp_vm
│   ├── meta/
│   │   ├── argument_specs.yml           # identical to cloud_gcp_vm
│   │   └── main.yml
│   └── README.md                        # stub notice
│
├── common/
│   └── tagging_gcp/                     [IMPL] — shared GCP label/annotation enforcement
│       ├── tasks/
│       │   └── main.yml
│       ├── defaults/
│       │   └── main.yml
│       ├── meta/
│       │   └── argument_specs.yml
│       └── README.md
│
├── postbuild_domain_join/               [STUB] — GCP path only, fail + TODO
│   ├── tasks/
│   │   └── main.yml                     # fail with TODO: domain, OU, creds source, OS support
│   ├── defaults/
│   │   └── main.yml
│   ├── meta/
│   │   └── argument_specs.yml
│   └── README.md
│
├── postbuild_agent_install/             [STUB] — GCP path only, fail + TODO
│   ├── tasks/
│   │   └── main.yml                     # fail with TODO: agent choice (Dynatrace/Datadog/CrowdStrike)
│   ├── defaults/
│   │   └── main.yml
│   ├── meta/
│   │   └── argument_specs.yml
│   └── README.md
│
├── provider/                            [EXISTING] — legacy provider roles (keep for reference)
│   ├── gcp_compute/                     [EXISTING] — will be deprecated in favor of cloud_gcp_vm
│   ├── aws_ec2/                         [EXISTING]
│   ├── azure_vm/                        [EXISTING]
│   ├── hyperv_vm/                       [EXISTING]
│   ├── nutanix_vm/                      [EXISTING]
│   └── vmware_vm/                       [EXISTING]
│
├── image/                               [EXISTING]
│   └── gcp_image/                       [EXISTING]
│
├── os/                                  [EXISTING]
│   ├── linux_baseline/                  [EXISTING]
│   └── windows_baseline/                [EXISTING]
│
├── domain/                              [EXISTING]
│   └── linux_domain_join/               [EXISTING]
│
├── security/                            [EXISTING]
│   ├── cis_linux/                       [EXISTING]
│   ├── security_agent/                  [EXISTING]
│   └── vulnerability_agent/             [EXISTING]
│
├── monitoring/                          [EXISTING]
│   └── monitoring_agent/                [EXISTING]
│
├── backup/                              [EXISTING]
│   └── backup_agent/                    [EXISTING]
│
├── dns/                                 [EXISTING]
│   └── dns_registration/                [EXISTING]
│
├── cmdb/                                [EXISTING]
│   └── servicenow_cmdb/                 [EXISTING]
│
├── platform/                            [EXISTING]
│   ├── run_state/                       [EXISTING]
│   ├── validate_request/                [EXISTING]
│   ├── resolve_configuration/           [EXISTING]
│   ├── naming/                          [EXISTING]
│   ├── image_resolver/                  [EXISTING]
│   ├── policy_gate/                     [EXISTING]
│   ├── preflight/                       [EXISTING]
│   ├── preflight_gcp/                   [EXISTING]
│   ├── inventory_generate/              [EXISTING]
│   ├── report/                          [EXISTING]
│   └── contract_guard/                  [EXISTING]
│
└── stage/                               [EXISTING]
    └── ...                              [EXISTING]
```

---

## Playbooks (NEW — simplified GCP-only entry points)

```
playbooks/
├── provision.yml                        [IMPL] — GCP provision entry point (uses provider_dispatch → cloud_gcp_vm)
├── post_build_domain_join.yml           [IMPL] — GCP path, targets dynamic inventory group
├── post_build_agent_install.yml         [IMPL] — GCP path, targets dynamic inventory group
├── build_server.yml                     [EXISTING] — keep as legacy master orchestration
├── README.md                            [EXISTING]
├── infrastructure/                      [EXISTING]
├── os/                                  [EXISTING]
├── post_build/
│   └── linux_post_build.yml             [EXISTING] — legacy
└── stages/                              [EXISTING] — legacy stage playbooks
    ├── provision_gcp.yml                [EXISTING]
    └── ...
```

---

## GitHub Actions (NEW)

```
.github/
└── workflows/
    ├── provision-gcp.yml                [IMPL] — reusable workflow, OIDC to GCP, workflow_dispatch + repository_dispatch
    ├── provision-gcp-dispatch.yml       [IMPL] — wrapper for repository_dispatch (ServiceNow)
    └── README.md                        [DOC] — usage docs
```

---

## AAP Templates as Code (NEW)

```
automation/
└── aap/
    ├── credentials/
    │   └── gcp_service_account.yml      [IMPL] — credential type definition
    ├── inventories/
    │   └── gcp_dynamic.yml              [IMPL] — dynamic inventory config
    ├── job_templates/
    │   ├── provision_gcp.yml            [IMPL] — survey: 8 vars, uses provision.yml
    │   ├── post_build_domain_join.yml   [IMPL] — survey: instance_id + domain params
    │   └── post_build_agent_install.yml [IMPL] — survey: instance_id + agent params
    └── workflow_templates/
        └── full_build_gcp.yml           [IMPL] — chains provision → domain_join → agent_install
```

---

## Documentation

```
docs/
├── PLAN.md                              [IMPL] — seeded with this scope, open questions, extension points
├── DECISIONS.md                         [IMPL] — architectural decisions log
├── servicenow_contract.md               [IMPL] — payload contract, mapping, auth, response format
├── README.md                            [EXISTING]
├── assumptions.md                       [EXISTING]
├── glossary.md                          [EXISTING]
├── open-questions.md                    [EXISTING] — add phase-specific questions
├── roadmap.md                           [EXISTING]
├── api/
│   └── api-contract.md                  [EXISTING]
├── architecture/                        [EXISTING] — update provider-abstraction.md, role-dependency-model.md
│   ├── architectural-decisions.md       [EXISTING]
│   ├── provider-abstraction.md          [EXISTING]
│   ├── role-dependency-model.md         [EXISTING]
│   └── ...
├── runbooks/                            [EXISTING]
├── security/                            [EXISTING]
└── testing/                             [EXISTING]
```

---

## Schemas (NEW — for input validation)

```
schemas/
├── business-request.schema.json         [EXISTING]
├── run-context.schema.json              [EXISTING]
├── run-result.schema.json               [EXISTING]
├── stage-result.schema.json             [EXISTING]
└── gcp-input-vars.schema.json           [IMPL] — JSONSchema for the 8 GCP input variables
```

---

## Scripts & Tests

```
scripts/
├── README.md                            [EXISTING]
└── lib/                                 [EXISTING]

tests/
├── README.md                            [EXISTING]
├── e2e/                                 [EXISTING]
├── fixtures/                            [EXISTING]
├── integration/                         [EXISTING]
├── molecule/                            [EXISTING]
└── security/                            [EXISTING]
    └── gitleaks.toml                    [IMPL] — add if missing
```

---

## Mock & Inventory (EXISTING)

```
mock/
├── README.md                            [EXISTING]
└── requirements/                        [EXISTING]

inventories/
├── README.md                            [EXISTING]
├── dev/                                 [EXISTING]
├── nonprod/                             [EXISTING]
└── prod/                                [EXISTING]
```

---

## Extension Points for Future Providers (Documented in PLAN.md, no directories created)

```
# These do NOT exist as directories in this phase.
# Documented in docs/PLAN.md § "Future Provider Extension Points"

roles/
├── cloud_oci_vm/                        [PLACEHOLDER] — documented extension point
├── cloud_vsphere_vm/                    [PLACEHOLDER] — documented extension point
├── cloud_ibm_vm/                        [PLACEHOLDER] — documented extension point
└── cloud_alicloud_vm/                   [PLACEHOLDER] — documented extension point
```

---

## Summary Counts

| Category | Count |
|---|---|
| `[IMPL]` — Full implementation | 18 paths |
| `[STUB]` — Fail + interface stubs | 5 paths |
| `[PLACEHOLDER]` — Documented only | 4 paths |
| `[DOC]` — Documentation only | 4 paths |
| `[EXISTING]` — Already present | 40+ paths |

---

## Key Architectural Notes

1. **New `cloud_gcp_vm` role is distinct from existing `provider/gcp_compute`** — The existing role uses `sba_` prefixed variables and a different contract. The new `cloud_gcp_vm` implements the unified 8-variable interface specified in this phase.

2. **`provider_dispatch` is the abstraction seam** — It routes `cloud=gcp` to `cloud_gcp_vm` and fails fast for `azure`/`aws` with a clear message. This keeps the playbook clean.

3. **Group vars replace hardcoded values** — All infrastructure coordinates (project, region, subnet, image, machine type) are derived from lookup tables in `group_vars/all/`, keyed by the 8 input variables.

4. **Post-build playbooks are independent** — They target hosts via dynamic inventory group (`gcp_servers`) or `add_host` from the provision run, and can be invoked separately.

5. **No secrets in repo** — GCP auth via Workload Identity Federation (GitHub Actions) and AAP credential (AAP runs). Placeholders like `<gcp-project-id>` used in examples.

6. **Molecule uses docker driver** — For fast logic tests; document the cloud-driver option for real integration testing.