# Ansible Role Dependency Model

Status: **Phase 1 — Proposed**

Role taxonomy, the dependency DAG, the provider role contract, ordering rules, the platform role
family, and the conventions that keep the role library maintainable as it grows.

Decisions: [AD-08](architectural-decisions.md#ad-08-provider-abstraction-via-a-fixed-contract--role-allow-list),
[AD-01](architectural-decisions.md#ad-01-single-entry-playbooks--staged-re-entry),
[AD-03](architectural-decisions.md#ad-03-configuration-resolver-is-a-python-library-not-jinja),
[C-12](architectural-decisions.md#2-requirement-conflict-register), [C-13](architectural-decisions.md#2-requirement-conflict-register).

---

## 1. Taxonomy

Six families. The family determines what a role may depend on, which is the main mechanism that
keeps the abstraction from eroding.

| Family | Path | Runs against | May depend on | Count |
|---|---|---|---|---|
| **P — Platform** | `roles/platform/` | The controller (`localhost`) | Nothing (or other P roles) | 10 |
| **C — Cloud provider** | `roles/provider/`, `roles/image/` | The controller | P only | 6 |
| **O — OS baseline** | `roles/os/` | A managed host | P only | 2 |
| **B — Post-build** | `roles/domain/`, `monitoring/`, `security/`, `backup/`, `dns/`, `cmdb/` | A managed host, or the controller for the CMDB role | P only | 12 |
| **S — Stage wrapper** | `roles/stage/` | The controller | P, C, O, B — and *only* in the declared order | 9 |
| **X — Experimental** | `roles/x/` | — | — | Sandbox only, excluded from `main` |

**The dependency rule that matters:** no role in family **C**, **O** or **B** may depend on
another role in its own family except through the stage wrapper, and **no** role may ever depend
on a role in a different provider family. `azure_vm` must not know that `aws_ec2` exists. If it
did, adding a cloud would require editing the existing roles, and the abstraction would be a
naming convention rather than a boundary.

---

## 2. Role Inventory

### 2.1 P — Platform (controller-side, no cloud mutation)

| Role | Responsibility | Stage | Notes |
|---|---|---|---|
| `platform/run_state` | Load/save `request`, `fingerprint`, `context`, `inventory`, `result.<stage>`, `run_result`; CAS operations; concurrency semaphore; TTL/GC | all | The only role that writes the state store. **Never** holds a credential beyond the state-store identity |
| `platform/validate_request` | Schema validation, closed enums, `count` bounds, forbidden fields, `schema_version` check | intake | Pure. No I/O beyond reading the contract |
| `platform/resolve_configuration` | Invoke the resolver; load `context.json` as a fact; assert the exit code | `resolve` | **No resolution logic.** It calls `scripts/resolve_configuration.py` ([AD-03](architectural-decisions.md#ad-03-configuration-resolver-is-a-python-library-not-jinja)) |
| `platform/naming` | Name/sequence/id allocation; short-name validity; collision diagnostics | `resolve` | Allocation is a CAS in `platform/run_state`; computation is pure |
| `platform/image_resolver` | Catalogue selection, expiry/revocation checks, pinning, AWS tag-query resolution | `resolve` | Wraps the resolver's image output and adds the post-resolution revocation re-check |
| `platform/policy_gate` | §25 policy rules, tag completeness, provider length limits, role-name allow-list | `resolve`, `validate` | Declared rules from `configuration/policies/`; no policy code |
| `platform/preflight` | The 22 live checks (§20) with read-only credentials | `validate` | **Read-only identity only** ([security-architecture.md §3.1 ](../security/security-architecture.md#31-the-provisionread-split-is-the-important-one)) |
| `platform/preflight_azure` / `_aws` / `_gcp` | Provider-specific pre-flight checks | `validate` | Called by `platform/preflight` from a **closed map** |
| `platform/inventory_generate` | Build `inventory.json` for exactly this run's targets | `provision` | From the `sba_instance_id` set — an exact set, never a tag filter ([AD-18](architectural-decisions.md#ad-18-inventories-hold-control-plane-hosts-only)) |
| `platform/report` | Roll up per-stage and per-host results; build `run_result.json` and the build report; set the exit code | `report` | The only role that serialises results for humans |
| `platform/contract_guard` | Re-validate the contract and `context.json` integrity after dispatch | all | Defence in depth: the 4th validation point ([security-architecture.md §4.1 ](../security/security-architecture.md#41-validation-happens-four-times-each-for-a-different-reason)) |

The `platform/` family is **not in §4's proposed tree.** It is added because §6, §7, §20, §21,
§23 and §25 require capabilities that must live somewhere, and named roles are what keep them
out of playbooks (§31: no giant playbook) and independently testable.

### 2.2 C — Cloud provider

| Role | Operations | Runs against |
|---|---|---|
| `provider/azure_vm` | `provision`, `get`, `validate`, `destroy`, `tag` | Controller |
| `provider/aws_ec2` | `provision`, `get`, `validate`, `destroy`, `tag` | Controller |
| `provider/gcp_compute` | `provision`, `get`, `validate`, `destroy`, `tag` | Controller |
| `image/azure_image` | `get_image` | Controller |
| `image/aws_image` | `get_image` | Controller |
| `image/gcp_image` | `get_image` | Controller |

All six implement the **same contract** ([§3 ](#3-the-provider-role-contract)) and are
interchangeable behind a closed dispatch map
([AD-08](architectural-decisions.md#ad-08-provider-abstraction-via-a-fixed-contract--role-allow-list)).

### 2.3 O — OS baseline

| Role | Family | Key responsibilities |
|---|---|---|
| `os/windows_baseline` | windows | WinRM TLS configuration; Windows Update; features/roles; pending-reboot detection and reboot sequencing; time sync; local admin from the resolved pattern; firewall default-deny with management ports restricted to the runner subnet; CIS Windows benchmark application and drift report; SIEM log forwarding |
| `os/linux_baseline` | linux | SSH hardening (key-only, root login off); package update; sysctl; SELinux/AppArmor; time sync; passwordless sudo with a restricted command set; auditd; firewall default-deny; CIS Linux benchmark; SIEM forwarding |

Both are selected by `sba_os_family` from the resolved configuration. **The stage machine never
branches on OS family** — it delegates, and the genuinely OS-specific mechanics live inside the
role ([logical-architecture.md §2.7 ](logical-architecture.md#27-l3--os--post-build)).

### 2.4 B — Post-build

| Role | Runs against | Key responsibilities | Ordering |
|---|---|---|---|
| `domain/windows_domain_join` | Host + AD | AD join; OU placement; GPO link; reboot; orphan computer-object cleanup on re-run; join verification | **4** |
| `domain/linux_domain_join` | Host + AD | Realm/AD join; SSSD; OU placement; idempotent re-join | **4** |
| `security/cis_linux`, `security/cis_windows` | Host | Benchmark remediation; drift report | 2 (invoked from baseline) |
| `security/security_agent` | Host + mgmt | EDR install from an internal allow-listed source; policy; **connectivity verification** | **5** |
| `security/vulnerability_agent` | Host + scanner | Scanner install; scheduled scan; **first-scan completion verification** | **5** |
| `monitoring/monitoring_agent` | Host + monitoring | Agent install; policy; heartbeat verification; **test alert where supported** | **5** |
| `backup/backup_agent` | Host + backup | Agent install; policy attach; **first-backup verification** | **5** |
| `dns/dns_registration` | DNS | A/CNAME/SRV/PTR upsert; TTL; **conflict detection, never silent overwrite** | **6** |
| `cmdb/servicenow_cmdb` | ServiceNow | CI upsert by `sba_instance_id`; relationship creation; ownership | **7** |

**Why agents come after domain join.** An agent installed before the host is domain-joined uses
a local account and a different policy path, and generally has to be reconfigured afterwards.
Domain join first, then agents, is both the correct technical order and the order an operator
would follow manually.

**Why DNS comes after agents.** A record pointing at a host that is not yet monitored is a
monitoring gap for that host; a record pointing at a host that is not yet in the domain is a
bigger problem. And why CMDB is last: the CI record should describe a server that is fully
configured, so the CMDB never holds a half-built asset.

**The "verify it works" rule.** Every agent role ends with a *functional* verification — a
heartbeat, a first scan, a first backup, a test alert — not a package-presence check. A stage
that installs a control and does not confirm it functions has not delivered the control
([security-architecture.md §9 ](../security/security-architecture.md#9-vulnerability-and-compliance-posture)).

---

## 3. The Provider Role Contract

The abstraction's actual content. A role that does not satisfy this is not a provider role, and
the contract test fails.

### 3.1 Inputs (all required)

```yaml
sba_provider:      azure | aws | gcp              # closed enum
sba_operation:     provision | get | validate | destroy | tag
sba_instance:      { index, short_name, fqdn, sba_instance_id }
sba_location:      { region, zone, availability_zone }
sba_network:       { vnet_ref, subnet_ref, security_policy_ref, private_ip }
sba_compute:       { size, os_disk, data_disks[] }
sba_image:         { catalog_id, provider, type, reference, version, generation? }
sba_identity_ref:  sba-cloud-azure-prod           # a NAME, never a value [AD-15]
sba_tags:          { ... }                        # TagMapper output, already provider-shaped
```

### 3.2 Outputs (all required, asserted by a contract test)

```yaml
sba_facts:
  server:   { instance_id, state, private_ip, fqdn, parent_scope }
  network:  { vnet_id, subnet_id, nic_id, private_ip, availability_zone, public_ip }
  disk:     { os_disk_id, data_disk_ids[], sizes_gb[] }
  image:    { applied_image_id, applied_version, applied_digest }
  tags:     { applied: {...}, verified: true }
sba_result: { changed, status, duration_s, error_code? }
```

### 3.3 Postconditions (asserted by the stage wrapper, not the role)

```
  the instance exists
  the instance is tagged tag-completely          [I-3]
  sba_instance_id is present in the metadata      [I-4]
  a private IP is assigned
  the management port answers
  applied image == the pinned image               (reproducibility)
```

`tags.verified: true` is a **read-back**, not an assertion about what was sent. A tag write can
fail silently on a provider side (IAM denying the tag API, a tag quota), and a platform that
trusts its own request would report complete metadata that is not there — breaking inventory,
cost attribution and audit simultaneously
([configuration-resolution.md §8.3 ](configuration-resolution.md#83-enforcement)).

### 3.4 `provision` idempotency (the most important behaviour in the platform)

```
  1. query for an instance with  tag SbaInstanceId == sba_instance_id
  2. found?
       yes -> ADOPT: validate it against the desired spec; fix drift; do not create
       no  -> CREATE with the full tag set
  3. read the tags back and compare to the intended set
  4. set sba_facts.*
```

This is what makes a re-run after a crash at minute 12 safe, and it is discharged by
[G-3](idempotency.md#3-guarantees). The lookup is by `sba_instance_id` and **not** by name,
because a name can be changed by an operator in a console while the tag cannot be — the tag is
the platform's own, immutable, authoritative record
([AD-05](architectural-decisions.md#ad-05-sba_instance_id-is-the-golden-join-key)).

### 3.5 Adding a provider

Checklist. Anything not on it is a sign the abstraction has a hole.

```
  [ ] roles/provider/<provider>_vm      implements all 5 operations
  [ ] roles/image/<provider>_image   implements get_image
  [ ] configuration/clouds/<cloud>.yml  with region_map, identity ref, TagMapper case
  [ ] closed dispatch map           entry for the provider, in the resolver
  [ ] TagMapper case                provider-shaped metadata + length limits asserted
  [ ] configuration/regions/*.yml    allowed_image_catalogues updated
  [ ] platform/preflight_<provider> live checks
  [ ] contract test                 the same suite passes for the new provider
  [ ] cloud-module confinement CI check updated to allow the new namespace
  [ ] cross-engine parity test      passes on both engines
  [ ] no existing role edited       ← the real test of the abstraction
```

---

## 4. Dependency DAG

```
                                   ┌───────────────────────────┐
                                   │  P: run_state             │  ← the only state writer
                                   │     platform/naming       │
                                   │     platform/inventory_*  │
                                   │     platform/report       │
                                   └─────────────┬─────────────┘
                                                 │ (all roles read context via run_state)
   ┌──────────────────────┐   ┌─────────────┬──┴──────────────┬────────────────────┐
   │ P: validate_request  │   │ P: resolve_ │                 │ P: contract_guard  │
   │ P: image_resolver    │   │   config    │                 └────────────────────┘
   │ P: policy_gate       │   │ P: policy_  │
   │ P: preflight_*      │   │   gate      │
   └──────────┬───────────┘   └──────┬──────┘
              │                      │
              └──────────┬───────────┘
                         │
        ═════════════════╪════════════  boundary: platform -> cloud
                         │
              ┌──────────┴───────────┐
              │ C: cloud/<p>_vm     │◀──┐
              │ C: image/<p>_image  │   │ closed dispatch map, never
              └──────────┬───────────┘   │ interpolated from input
                         │               │
        ═════════════════╪════════════   ┘
                         │  boundary: cloud -> managed host
              ┌──────────┴───────────┐
              │ O: os/<family>_base  │
              │ B: domain/*          │
              │ B: security/*        │
              │ B: monitoring/*      │
              │ B: backup/*          │
              │ B: dns/*             │
              │ B: cmdb/*            │
              └──────────┬───────────┘
                         │
              ┌──────────┴───────────┐
              │ S: stage/<name>      │  wraps a stage, in order
              │    load -> run ->    │  enforces the result contract
              │    result -> release │
              └─────────────────────┘
```

### 4.1 Layer boundaries and what crosses them

| Boundary | Crosses | Rule |
|---|---|---|
| Platform → Cloud | Resolved configuration + a scoped cloud identity | A `C` role never re-derives configuration and never reads the catalogue |
| Cloud → Host | WinRM/SSH to an exact `sba_instance_id` set | An `O`/`B` role never targets a host not in the generated inventory |
| Host → Management | Scoped integration identities, per platform | A `B` role never uses another platform's credential |
| Any → State | `context.json` in, `result.<stage>.json` out | A role never reaches into another stage's result |

### 4.2 Cycle avoidance

The DAG is acyclic by construction: `P` has no dependencies, `C` depends on `P`, `O`/`B` depend
on `P`, `S` depends on all. There is no way to express a cycle, which means there is no cycle
to accidentally create.

The one place a cycle *could* appear is the OS baseline invoking the CIS roles. That is
resolved by making it a **one-way** dependency: `os/*_baseline` invokes `security/cis_*`, and
`security/cis_*` never invokes anything. The CIS roles are leaves.

---

## 5. The `stage/` Family

One wrapper per stage. It is the reason §5's "each stage independently executable" is a
property of the system rather than a convention.

```
  roles/stage/<name>/tasks/main.yml

    - platform/contract_guard       # re-validate the contract and context integrity
    - platform/run_state           # load context.json; check the stage's prior result
    - <skip if the prior result is SUCCESS and not forced>
    - <the stage's roles, in order, with tags>
    - platform/run_state           # write result.<stage>.json   [I-6]
    - platform/report             # roll up; set the exit code
    - platform/run_state           # release resources (semaphore, locks)
    always:
      - platform/run_state       # emit a terminal status even on an exception
```

| Element | Purpose |
|---|---|
| The guard first | Rejects a tampered `context.json` before any role acts |
| The prior-result check | Makes re-running a stage a no-op unless forced, and makes re-running a *failed* stage the natural remediation |
| `result.<stage>.json` written **before** the exit code | A result exists even when the run is about to fail |
| The `always:` block | A terminal status is emitted even on an unexpected exception, so a run can never leave ServiceNow waiting forever |
| Resource release in `always:` | A failed run does not leak a concurrency slot, which would eventually deadlock an environment |

Every one of those five elements is a specific, identified failure mode being prevented. That
is the difference between a wrapper and boilerplate.

---

## 6. Stage Composition

The single entry playbook's stage table. The orchestration content that GitHub Actions and AAP
both execute, and neither of them duplicates
([AD-01](architectural-decisions.md#ad-01-single-entry-playbooks--staged-re-entry)).

| Stage | Roles, in order | `serial` | Write scope |
|---|---|:--:|---|
| `validate` | `contract_guard` → `policy_gate` → `preflight` → `preflight_<p>` | — | Read-only |
| `provision` | `inventory_generate` → `image/<p>_image` → `cloud/<p>_vm` → `wait_for_ready` | per config | Cloud control plane |
| `os_config` | `os/<family>_baseline` | per config | Guest |
| `validate_os` | `os_validator` (assertions only) | — | Read-only |
| `domain_join` | `domain/<family>_domain_join` → `wait_for_domain` | per config | Guest + AD |
| `install_agents` | `security_agent` → `vulnerability_agent` → `monitoring_agent` → `backup_agent` | per config | Guest + mgmt |
| `dns` | `dns_registration` | per config | DNS |
| `cmdb` | `servicenow_cmdb` | — | ServiceNow |
| `report` | `report` | — | State only |
| `destroy` | `inventory_generate` → `cloud/<p>_vm` (destroy) → `dns` (cleanup) → `cmdb` (retire) | per config | Cloud + DNS + CMDB |

**Ordering constraints, and why each exists:**

```
  validate       before anything           cheapest rejection point
  provision      before os_config           a host must exist to configure
  os_config      before validate_os         compliance is assessed after configuration
  validate_os    before domain_join         joining a non-compliant host is worse
  domain_join    before install_agents      agents need directory-integrated identity
  install_agents before dns                 a record should not point at an unmonitored host
  dns            before cmdb                the CI record references the FQDN
  cmdb           last                       the record describes a finished server
  report         always last                the roll-up needs every stage result
```

The `domain_join` → `install_agents` ordering deserves emphasis because it is the one most
often got wrong in hand-built automation: an agent installed before domain join runs under a
local account, enrolls against a different policy path, and usually has to be reconfigured
afterwards. Automating it in the wrong order produces servers that *look* compliant and are not.

---

## 7. Credential and Logging Rules

Per-role, mechanically enforced.

| Rule | Enforcement |
|---|---|
| A credential is referenced by **name** from `defaults/main.yml` | Never a value ([AD-15](architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs)) |
| No credential value in any `vars/`, `group_vars/`, `host_vars/` | CI grep gate |
| Every task consuming a credential sets `no_log: true` | `ansible-lint` custom rule; a violation fails the build |
| A `no_log` task registers only a **derived boolean** | Lint rule; keeps diagnostics without exposing values |
| No `shell`/`command` where an idempotent module exists | `ansible-lint` |
| `no_log` never applied to a whole play | It would hide real failures; per-task only |
| `debug`/`set_stats` never prints a resolved configuration | Custom CI check on `debug` usage |
| `diff: true` only where the value is not sensitive | Lint rule + review |

```yaml
# roles/domain/windows_domain_join/defaults/main.yml
sba_domain_join_credential: sba-domainjoin     # a name. reviewed, committed, no value.
sba_domain_join_account: "svc-join-sba"        # an account name. not a secret.

# roles/domain/windows_domain_join/tasks/main.yml  (shape, Phase 4)
- name: Join the Active Directory domain
  ansible.windows.win_domain_join:
    domain_name: "{{ sba_domain.name }}"
    domain_user_name: "{{ sba_domain_join_account }}"
    domain_user_password: "{{ sba_domain_join_credential | password(lookup('ansible.builtin.env', 'SBA_CRED_LOOKUP')) }}"
    ou_path: "{{ sba_domain.ou }}"
  register: sba_domain_join_result
  no_log: true
```

The credential indirection resolves through the engine's credential store at run time. A value
in an environment variable read by a lookup is acceptable only because that variable is itself
injected by the engine from the store and is never written to a file or a log; where the engine
supports a direct credential reference, that is used instead.

---

## 8. Naming and Layout Conventions

| Convention | Rule | Rationale |
|---|---|---|
| Directory layout | `<family>/<role_name>` per §4 | Groups by family, which is the dependency boundary |
| Role names | `^[a-z][a-z0-9_]*$` per segment | `ansible-lint` `role-name`; the schema is widened to permit one `/` level ([C-12](architectural-decisions.md#2-requirement-conflict-register)) rather than skipping the rule, because skipping it would also disable it for genuinely invalid names |
| `main.yml` | The default entry point | Convention |
| Tag files | `tags/main.yml` per role | Playbook-level tags apply automatically |
| Variables | `sba_` prefix for platform-set, plain names for role-local | Distinguishes the platform contract from role internals |
| Facts | `sba_facts.*` namespaced | Prevents collision with provider facts |
| Defaults | Every variable in `defaults/main.yml`, never inline in a task | Documentation and override-ability |
| Meta | `meta/main.yml` with `dependencies` where genuinely required | A hidden dependency in a task file is invisible |
| `allow_duplicates` | Never | Non-idempotent by construction |
| `collections:` keyword | Declared in `meta/main.yml` for anything outside `ansible.builtin` | Ansible 2.16+ best practice; makes a role usable outside the EE |
| Handlers | Only for things that genuinely need deferral (a service restart after a config change) | `notify` on a handler is not idempotency |
| `changed_when` | Explicit wherever a module reports `changed` unconditionally | §17's "define state" |
| `check_mode` | Supported wherever feasible; unsupported paths documented in the role README | §17's "use check mode where possible" |

---

## 9. Standards Applied to Every Role

§17, enforced rather than advised.

| Standard | Enforcement |
|---|---|
| `ansible.builtin.*` and fully qualified collection names | `ansible-lint` `fqcn` — **blocking** ([I-9](architectural-decisions.md#3-cross-cutting-invariants)) |
| Plays and tasks named | `ansible-lint` `name` |
| `state:` declared | `ansible-lint` |
| Idempotent modules preferred over `shell`/`command` | `ansible-lint` |
| `register` meaningful results | Review + `changed_when` rule |
| Handlers for deferred actions | Review |
| Tags on every role | `ansible-lint` |
| `check_mode` support | `ansible-lint` `check-mode` |
| Variables validated, fail early | `platform/validate_request` + `assert` with a named message |
| No hard-coded infrastructure values | CI grep gate ([I-8](architectural-decisions.md#3-cross-cutting-invariants)) |
| No dynamic role names from input | Static import list + closed enum ([AD-08](architectural-decisions.md#ad-08-provider-abstraction-via-a-fixed-contract--role-allow-list)) |
| Provider modules confined to `roles/cloud`+`roles/image` | CI grep gate |
| Batching where it matters | `serial` per stage |
| Staging (directory-based) for role downloads | Not applicable — roles are in-repo |

### 9.1 A role is done when

```
  [ ] Implements the family contract (inputs, outputs, postconditions)
  [ ] Passes `ansible-lint` with zero findings
  [ ] Passes `ansible-playbook --syntax-check` and `--list-tasks`
  [ ] Idempotent: a second run reports `changed: 0`
  [ ] Idempotent: a run after a partial failure produces the intended state
  [ ] `check_mode` supported, or the exceptions documented in the role README
  [ ] Every credential-consuming task has `no_log: true`
  [ ] A `defaults/main.yml` with every variable documented
  [ ] `meta/main.yml` declaring `collections` and any `dependencies`
  [ ] A Molecule scenario for the role, with an idempotence scenario
  [ ] A unit test for any pure logic the role contains
  [ ] Tag-complete metadata applied at create, and read back
  [ ] Returns a structured result the stage wrapper can roll up
  [ ] Documented failure modes map to registered error codes
  [ ] Reviewed against the layering violations list
        [logical-architecture.md §5](logical-architecture.md#5-layering-violations-to-reject-in-review)
```

That checklist is the practical form of the architecture. Roles that satisfy it compose into a
platform that behaves as designed; roles that skip it produce a system that works on the happy
path and surprises everyone on the first `PARTIAL`.

---

## 10. Growth Model

How the library scales without the dependency graph becoming unreadable.

| Roles | Expected state |
|---:|---|
| 1-30 | The 30 in §2. Readable as a table |
| 30-60 | Group by family; the stage table becomes the primary navigation |
| 60-100 | Split the entry playbook's stage table into generated per-stage playbooks from a single source of truth; keep **one** entry point |
| 100+ | Extract the reusable roles into an Ansible **Collection** ([AD-13](architectural-decisions.md#ad-13-this-repo-is-an-ansible-project-not-a-collection)) so other teams can consume them independently. A mechanical move: `roles/collections/<ns>/<name>/roles/…` |

The threshold for the Collection split is worth stating now, because it is a foreseeable
pressure and the answer should not be improvised when it arrives: **if another team wants to
consume these roles, the roles become a Collection.** Until then they are an Ansible Project,
which matches §4's tree and is the right shape for a platform consumed by AAP and GHA rather
than by many independent projects.

---

## 11. Next

- Stage-by-stage lifecycle: [request-lifecycle.md](request-lifecycle.md)
- Stage table and adapter thinness: [servicenow-aap.md §5 ](servicenow-aap.md#5-workflow-template-design)
- Provider detail: [provider-abstraction.md](provider-abstraction.md)
- Testing a role: [../testing/testing-strategy.md](../testing/testing-strategy.md)
