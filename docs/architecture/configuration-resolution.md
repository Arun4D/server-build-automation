# Configuration Resolution Architecture

Status: **Phase 1 — Proposed**

The design of the layer that turns a 9-field business request into a complete, validated,
provenance-tracked technical configuration. This is the component that makes §2 of the bootstrap
achievable — *"the user should ideally provide only business inputs; the platform derives
technical values from approved configuration"*.

Decisions: [AD-03](architectural-decisions.md#ad-03-configuration-resolver-is-a-python-library-not-jinja),
[AD-06](architectural-decisions.md#ad-06-two-name-model-short-netbios-name--long-fqdn),
[AD-07](architectural-decisions.md#ad-07-image-catalogue-with-pinning-and-expiry),
[AD-11](architectural-decisions.md#ad-11-gcp-labels-for-indexable-subset-annotations-for-full-metadata),
[AD-22](architectural-decisions.md#ad-22-resolver-is-read-only-and-side-effect-free),
[C-01](architectural-decisions.md#2-requirement-conflict-register), [C-02](architectural-decisions.md#2-requirement-conflict-register),
[C-13](architectural-decisions.md#2-requirement-conflict-register).

---

## 1. The Problem This Solves

A requester states intent:

```json
{ "application": "PAYMENTS", "environment": "PROD", "cloud": "AZURE",
  "region": "AMS", "server_role": "APPLICATION", "os": "WINDOWS", "count": 2 }
```

The platform must determine, without asking anyone anything else:

```
  Azure subscription        resource group        VNet        subnet
  NSG / security policy     VM size + family      availability zone
  managed disk policy       OS disk size          data disks
  image (pinned version)    image generation      security baseline
  naming (long + short)     DNS zone             domain + OU
  backup policy             monitoring policy     agent set
  tags / labels / annotations   data classification   cost centre
  owner / support group     CMDB class + category
```

Doing that well requires: a documented hierarchy, deterministic precedence, conflict detection,
provenance for every value, unit-testable behaviour, and a hard boundary against
infrastructure values leaking in from the request.

---

## 2. Architecture

```
  +------------------------------------------------------------------+
  |  INPUT                                                             |
  |    run contract  (9 fields, closed schema)                        |
  |    catalog_version                                                |
  |    as_of            (explicit; the only clock input)              |
  +-------------------------------+----------------------------------+
                                  |
  +-------------------------------v----------------------------------+
  |  sba_resolver  (pure Python; no I/O, no network, no clock)        |
  |                                                                  |
  |   1. SELECT     load the catalogue slice implied by the request  |
  |   2. MERGE      apply the 9-level precedence hierarchy            |
  |   3. VALIDATE   schema + type + enum + bounds + completeness      |
  |   4. ALLOCATE   names (long + short), sequence, instance ids      |
  |   5. SELECT IMAGE   catalogue entry -> pinned provider reference   |
  |   6. MAP TAGS   business metadata -> provider-shaped metadata     |
  |   7. EVALUATE POLICY   §25 rules over the resolved configuration  |
  |                                                                  |
  +-------------------------------+----------------------------------+
                                  |
              +-------------------+-------------------+
              |                                       |
              v                                       v
  +-----------------------+            +--------------------------------+
  | resolved_configuration|            | diagnostics                    |
  |  + provenance per leaf |            |  errors[]   (fatal)            |
  |  + allocations          |            |  warnings[] (advisory)         |
  +-----------+-----------+            +--------------------------------+
              |
              v
     context.json  ->  run-state store  ->  stage machine
              |
              +--> SEPARATE, credentialed, later:
                  pre-flight validation (quota, existence, network,
                  domain-name uniqueness, approval re-verification)
                  [AD-22: the resolver must not do these]
```

### 2.1 Why a Python library and not Ansible

| Requirement | Jinja / `group_vars` | Python resolver |
|---|---|---|
| 9-level precedence with conflict detection | No native conflict semantics; `combine` is last-wins and silent | Explicit, with typed diagnostics |
| Provenance per value | Not expressible | Native |
| Output schema validation | Awkward on registered results | Trivial |
| Exhaustive unit tests (§26) | Assertion failures inside a play run | Table-driven, fast, CI-friendly |
| Callable from GHA, AAP **and** a future HTTP API | No | Yes |
| Testable with no cloud account and no AAP | No | Yes |
| No cloud credential ever handled | Possible but easy to violate ([AD-22](architectural-decisions.md#ad-22-resolver-is-read-only-and-side-effect-free)) | Structural: no I/O at all |

§9 says "prefer clean provider abstraction over excessive Jinja complexity". The resolver *is*
that clean abstraction; expressing it in Jinja would be exactly the complexity §9 warns about.

### 2.2 Resolver guarantees

| Guarantee | Enforcement |
|---|---|
| Pure function | No `socket`, no `requests`, no `open()` on non-catalogue paths, no `datetime.now()`. CI asserts no network import in `scripts/lib/sba_resolver/`; unit tests monkeypatch `socket.socket` to raise |
| Deterministic | Same `(request, catalog, as_of)` ⇒ byte-identical output. Golden-file tests |
| Total | Either a complete `resolved_configuration` or a fatal diagnostic. Never partial |
| Closed | Unknown enum ⇒ `UNSUPPORTED_ENUM_VALUE`, never passthrough ([AD-20](architectural-decisions.md#ad-20-additive-schema-versioning-only)) |
| Explaining | Every leaf carries `provenance: {source, key, level}` |
| Non-secret | Contains no credential, ever ([AD-15](architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs)) |

---

## 3. Resolution Hierarchy

§7's hierarchy, with the mechanism and the override semantics made explicit.

```
  LEVEL 0  ENTERPRISE POLICY        (highest priority floor — non-overridable)
  ────────────────────────────────────────────────────────────────────
  LEVEL 1  REQUEST                 (the 9 business fields)
  LEVEL 2  APPLICATION             configuration/applications/<app>.yml
  LEVEL 3  ENVIRONMENT            configuration/environments/<env>.yml
  LEVEL 4  CLOUD                  configuration/clouds/<cloud>.yml
  LEVEL 5  REGION                  configuration/regions/<region>.yml
  LEVEL 6  SERVER ROLE             configuration/server_roles/<role>.yml
  LEVEL 7  OS                      configuration/os/<family>.yml
  LEVEL 8  DEFAULTS                configuration/defaults.yml
```

### 3.1 Precedence, stated unambiguously

Later layers **refine** earlier ones; they never weaken a policy floor.

| Rule | Behaviour | Example |
|---|---|---|
| **P1 — Explicit is highest** | A key explicitly set at a *more specific* level wins over a general one | `environments/prod.yml` sets `batch_serial: 1`; `server_roles/database.yml` sets `batch_serial: 2`; the **more specific role** wins (LEVEL 6 > LEVEL 3) |
| **P2 — Policy floor** | LEVEL 0 cannot be overridden by any level. A value violating a policy floor is a **fatal diagnostic**, not a lower-priority value | `prod` + `batch_serial: 8` > `policies/prod.yml` `max_batch_serial: 2` ⇒ `POLICY_VIOLATION` |
| **P3 — Same-level conflict** | Two files contributing the same key at the same level with different values ⇒ `PRECEDENCE_CONFLICT`, fatal. Never last-wins | `applications/payments.yml` and `applications/payments-eu.yml` both set `os_family` ⇒ fatal |
| **P4 — Deep merge** | Mappings merge recursively; scalars and lists are replaced wholesale, never appended | `security.required_agents` from a role replaces the OS default, it does not concatenate |
| **P5 — Lists are ordered and explicit** | If a list must be combined, the combining layer must say so via `merge_strategy: append` on that key. Default is `replace` | `security.required_agents: {merge_strategy: append}` |
| **P6 — No implicit wildcard** | A configuration file cannot match on a dimension the request did not supply. There are no glob patterns | You cannot write a rule that "applies to all apps in EU" — you write it per app or per region |
| **P7 — Selection is by closed enum** | Every level is selected by an exact key from the request | A request for `cloud: ONPREM` is `UNSUPPORTED_ENUM_VALUE`, not a fallback to a default |

**P1's subtlety — "more specific" is not "later in the list".** A database role in `dev` must
still be able to take precedence over a generic environment default in `prod`-style config,
and a role-level `os_family` hint must not override an explicit `os` from the request. The
implementation ranks by *(specificity, explicitness)*, not by level order, and the ranking is
declared in one table so it is reviewable:

```yaml
specificity:            # higher wins, per key
  request_explicit:   100   # a field the requester actually supplied
  role_specific:       90   # server_roles/<role>.yml
  os_specific:         80   # os/<family>.yml
  application:         70   # applications/<app>.yml
  region_specific:     60   # regions/<region>.yml
  environment_specific:50   # environments/<env>.yml
  cloud:         request-lifecycle.md oud>.yml
  defaults:            10   # defaults.yml
policy_floor:        1000   # never overridable; violation is fatal  [P2]
```

`request_explicit` scoring highest is the mechanism that makes §2 work: a requester who says
`os: WINDOWS` gets Windows even if the application default says Linux — and the *policy* layer
still decides whether that combination is permitted.

### 3.2 Provenance

Every resolved leaf records where it came from. This is what turns a rejection into an
explanation and a config change into a reviewable diff.

```json
{
  "vm_size": {
    "value": "Standard_D4s_v6",
    "provenance": {
      "source": "configuration/server_roles/application.yml",
      "key": "compute.sizes.default",
      "level": "SERVER_ROLE",
      "specificity": 90,
      "overrode": ["configuration/applications/payments.yml#compute.sizes.default"]
    }
  }
}
```

`overrode` is populated only where a value actually displaced another — which makes
`git diff` on a configuration file a meaningful review artefact: a reviewer can see exactly
which downstream values a change affects, and the resolved-config hash in the RITM tells them
whether a given build was affected.

---

## 4. Precedence and Merge Semantics in Practice

Worked example, `PAYMENTS / PROD / AZURE / AMS / APPLICATION / WINDOWS / count 2`.

```yaml
# LEVEL 0 policies/production.yml          (floor — non-overridable)
max_batch_serial: 1
require_change_reference: true
allowed_vm_families: [standard_d, standard_e]
require_backup: true
require_monitoring: true
require_tag_set: [full]

# LEVEL 1 request
application: PAYMENTS   environment: PROD   cloud: AZURE   region: AMS
server_role: APPLICATION  os: WINDOWS   count: 2

# LEVEL 2 configuration/applications/payments.yml
compute: { sizes: { default: standard_d4s_v6, max: standard_d8s_v6 } }
network: { tier: app, expose_public: false }
os_family: windows
disks: { data_count: 1, data_size_gb: 256 }
backup:  { schedule: nightly, retention_days: 35 }

# LEVEL 3 configuration/environments/prod.yml
network: { tier_override_allowed: false, private_only: true }
compute: { allowed_families: [standard_d, standard_e] }
batch_serial: 1
approval: { required: true }

# LEVEL 4 configuration/clouds/azure.yml
provider: azure
region_map: { AMS: westeurope, NRT: japaneast }
tags: { ManagedBy: Ansible, AutomationPlatform: SBA }
identity: { credentials_ref: sba-cloud-azure-prod }

# LEVEL 5 configuration/regions/ams.yml
location: westeurope
availability_zones: [1, 2, 3]
data_residency: eu
allowed_image_catalogues: [ent-windows, ent-linux]

# LEVEL 6 configuration/server_roles/application.yml
compute: { sizes: { default: standard_d4s_v6 request-lifecycle.md security: { baseline: cis_windows_2025_1, required_agents: [edr, vuln_scanner] }
monitoring: { policy: standard, check_interval_s: 60 }
discovery: { dns_zone: corp.example.com, primary_record: fqdn }

# LEVEL 7 configuration/os/windows.yml
os_family: windows
build: { update: true, features: [NetFx3, SMB1Removal], gpo_refresh: true }
management: { winrm_port: 5986, winrm_transport: ntlm-in-tls }
account: { local_admin_pattern: "adm-{short_name}" }
```

Resolution result (excerpt; the complete document also carries provenance for every leaf):

```json
{
  "schema_version": "1.0.0",
  "catalog_version": "2026.09.1",

  "identity": {
    "request_id": "RITM0012345", "correlation_id": "…", "run_id": "…",
    "application": "PAYMENTS", "environment": "PROD",
    "provider": "azure", "cloud": "AZURE", "region": "AMS",
    "location": "westeurope", "os_family": "windows"
  },

  "cloud_role": "azure_vm", "image_role": "azure_image",

  "placement": {
    "subscription_ref": "payments-prod-subscription",
    "resource_group": "rg-payments-prod-ams",
    "availability_zone": 1,
    "tags_source": "TagMapper/azure"
  },

  "network": {
    "vnet_ref": "vnet-payments-prod-ams",
    "subnet_ref": "snet-payments-prod-app",
    "security_policy": "payments-app-nsg",
    "private_only": true
  },

  "compute": {
    "size": "Standard_D4s_v6",
    "os_disk": { "size_gb": 127, "type": "Premium_LRS", "delete_with_vm": true },
    "data_disks": [ { "size_gb": 256, "type": "Premium_LRS", "lun": 0 } ]
  },

  "image": {
    "catalog_id": "win-2025-enterprise",
    "provider": "azure",
    "type": "SharedImageVersion",
    "gallery": "org_images",
    "image": "windows-2025-enterprise",
    "version": "12.3",
    "baseline": "cis_windows_2025_1",
    "pinned_at": "2026-09-14T09:12:44Z"
  },

  "naming": {
    "pattern": "{app_code}-{env_code}-{role_code}-{region_code}-{seq:03d}",
    "instances": [
      { "index": 1, "short_name": "pypa001",
        "fqdn": "pay-prod-app-ams-001.corp.example.com",
        "sba_instance_id": "9b1d…", "dns_zone": "corp.example.com" },
      { "index": 2, "short_name": "pypa002",
        "fqdn": "pay-prod-app-ams-002.corp.example.com",
        "sba_instance_id": "4c7e…", "dns_zone": "corp.example.com" }
    ]
  },

  "os_build": {
    "update": true, "features": ["NetFx3", "SMB1Removal"], "gpo_refresh": true,
    "winrm_port": 5986, "local_admin_pattern": "adm-{short_name}"
  },

  "security": { "baseline": "cis_windows_2025_1",
                "required_agents": ["edr", "vuln_scanner"], "policy": "enterprise" },
  "monitoring": { "policy": "standard", "check_interval_s": 60 },
  "backup": { "schedule": "nightly", "retention_days": 35, "policy": "gold" },
  "dns": { "zone": "corp.example.com", "primary_record": "fqdn", "ttl": 300 },
  "domain": { "name": "corp.example.com", "ou": "OU=Servers,OU=Payments,DC=corp,DC=example,DC=com" },
  "cmdb": { "class": "cmdb_ci_computer", "category": "production",
            "assignment_group": "app-pay-prod" },
  "lifecycle": { "stage": "provision", "serial": 1, "on_failure": "retain" },

  "policy_evaluation": { "rules_evaluated": 34, "violations": [], "advisories": [] }
}
```

Note what is *not* here: no credential, no token, no key, and nothing the requester supplied
beyond the 9 fields. Note also that `sba_cloud_role: azure_vm` is emitted by the resolver from
a **closed map** — it is never an interpolation of request data
([AD-08](architectural-decisions.md#ad-08-provider-abstraction-via-a-fixed-contract--role-allow-list)).

---

## 5. Catalogue Layout

```
configuration/
  defaults.yml                 LEVEL 8
  policies/                    LEVEL 0 — the floor
    enterprise.yml               global invariants (tag set, allowed clouds, naming)
    production.yml               prod-specific floor
    nonproduction.yml
    development.yml
  applications/<app>.yml       LEVEL 2
  environments/<env>.yml       LEVEL 3
  clouds/<cloud>.yml           LEVEL 4   (includes region_map, TagMapper config)
  regions/<region>.yml         LEVEL 5
  server_roles/<role>.yml      LEVEL 6
  os/<family>.yml              LEVEL 7
  images/catalog.yml            image abstraction + approval metadata  (§8)
  routing/engine_routing.yml   which engine runs which environment  [AD-09]
  ownership.yml                owner / support group / cost centre per application
```

Splitting `policies/` per environment is deliberate: the production floor must be a small,
obviously-scoped, separately-reviewed file. A monolithic policy file drifts toward being
advisory, and a policy nobody can review in one screen is not a control.

**`ownership.yml` is separate from `applications/`** because it changes on a completely
different cadence (org charts, cost centres, support models) from application technical
configuration. Keeping them apart means an ownership change never risks touching a technical
default, and vice versa.

---

## 6. Naming Engine

The most constraint-dense component, because of [C-01](architectural-decisions.md#2-requirement-conflict-register).

### 6.1 The two-name model

| Attribute | Constraint | Source | Example |
|---|---|---|---|
| `long_name` | The §23 pattern, verbatim | `{app_code}-{env_code}-{role_code}-{region_code}-{seq:03d}` | `pay-prod-app-ams-001` |
| `fqdn` | `{long_name}.{zone}` | Zone from role/region config | `pay-prod-app-ams-001.corp.example.com` |
| `short_name` | **`[a-z0-9][a-z0-9-]{0,13}[a-z0-9]`** (≤15, no leading/trailing hyphen) | Deterministic compaction (§6.3) | `pypa001` |
| `dns_owner` | The record owner name in the Windows/AD zone | = `short_name` on Windows, `long_name` on Unix DNS | — |

`short_name` is the Windows computer name and therefore bounded by the **15-character SAM
account name** limit. It is also the DNS owner name in zones served by the Windows DNS servers,
so it must be globally unique in the domain, not merely within the resource group.

### 6.2 Why the §23 example cannot be the Windows computer name

```
  pay-prod-app-ams-001     19 characters
  Windows SAM limit         15 characters
  ─────────────────────────────────────
  Result: cannot domain-join.
```

§23's pattern is preserved intact for the FQDN because it is valuable: it is readable,
greppable, self-documenting, and matches the naming standard an enterprise already has. It is
simply not the *computer name*. [AD-06](architectural-decisions.md#ad-06-two-name-model-short-netbios-name--long-fqdn).

### 6.3 Short-name compaction algorithm

Deterministic, collision-detectable, and it fails loudly rather than producing something ugly.

```
  inputs:  app_code, env_code, role_code, region_code, seq
  codes:   pre-compacted 3-4 character codes from configuration
           (payments->pay, production->prod, application->app, amsterdam->ams)
           NOT derived by truncating at resolve time — configured, so they are
           reviewable and stable when an application is renamed.

  attempt 1 (natural, when it fits):
      {app[0:3]}{env[0:1]}{role[0:3]}{seq:03d}
      pay + p + app + 001  ->  "pypapp001"   (9 chars)  ACCEPT if unique

  attempt 2 (with region, when attempt 1 collides):
      {app[0:3]}{env[0:1]}{role[0:2]}{region[0:1]}{seq:03d}
      pay + p + ap + a + 001  ->  "pypapa001"  (9 chars)  ACCEPT if unique

  attempt 3 (reserved namespace, deterministic salt):
      {app[0:3]}{env[0:1]}{role[0:2]}{seq:04d}   (4-digit sequence)
      -> "pypap0001"  ACCEPT if unique

  exhausted  ->  NAME_UNRESOLVABLE (fatal).  Never truncate, never append random
                 characters, never reuse a name. A collision is escalated to the
                 platform team, who allocate a code in configuration. That is a
                 configuration change under change control — which is exactly the
                 right place for the decision to live.
```

Why not random suffixes? Because `pay-prod-app-ams-001` → `pypa7f2` is unsearchable by a human
during an incident, and because a name that cannot be derived from its intent is a name that
someone will eventually "fix" by hand in the console, breaking the model. Deterministic and
failing loudly is strictly better than random and working.

The **`seq:04d` variant is why the short-name namespace is scarce**: a 4-digit sequence per
scope is 10 000 names, but the *domain-wide* namespace is shared, so short names must be
reserved atomically per `{env, app_code, role_code}` scope, and pre-flight checks domain-wide
uniqueness ([request-lifecycle.md ](request-lifecycle.md#phase-4--pre-flight-validation-stage-validate-20)).

### 6.4 Sequence allocation

```
  scope            = {env_code, app_code, role_code}       (short-name sequence)
  long_seq_scope   = {env_code, app_code, role_code, region_code}   (long-name sequence)

  allocation:
    1. compute a deterministic key:  sha256(correlation_id + ":" + index)
    2. CAS the counter object:  { next: N } -> { next: N + count }
    3. assign the reserved block [N, N+count) to this run
    4. persist the block in context.json BEFORE any further step
```

Four properties matter:

| Property | Why |
|---|---|
| **Block reservation, not per-name CAS** | `count: 4` must reserve 4 names atomically. Per-name CAS can interleave with another run and produce a non-contiguous block, which is confusing but not harmful — however a *block* CAS is also cheaper (one write, not four) |
| **Persisted before use** | If the run dies after reserving, the names are burned, not reused. Reusing them would mean a DNS record from a previous half-run points at a server that does not exist |
| **Deterministic from `correlation_id`** | A re-run of resolution for the same correlation **reuses** the same block from `context.json` and never re-reserves ([idempotency.md §7 ](idempotency.md#7-per-stage-idempotency-contract)) |
| **Separate scope for long and short** | The long-name sequence is per-region; the short-name sequence is domain-wide. Conflating them exhausts one namespace when the other is fine |

`sba_instance_id` is minted as a UUIDv4 per index, stored in `context.json` at the same moment,
and never regenerated ([AD-05](architectural-decisions.md#ad-05-sba_instance_id-is-the-golden-join-key)).

---

## 7. Image Resolution

§8 requires an abstraction, approval metadata, and no requester-supplied image IDs.

### 7.1 Catalogue entry

```yaml
# configuration/images/catalog.yml
- id: win-2025-enterprise
  os_family: windows
  os_version: "2025"
  architecture: x86_64
  classification: enterprise
  approval_status: approved            # approved | pending | deprecated | revoked
  baseline: cis_windows_2025_1
  published_at: "2026-03-01"
  expires_at:   "2026-09-01"           # gates NEW selection
  revoked_at:   null                   # emergency; gates EVERYTHING
  security_attestation: "ATT-2026-0142"
  support:
    owner: "cloud-platform-windows"
    escalation: "windows-oncall@corp.example.com"
  providers:
    azure:
      type: SharedImageVersion
      gallery: org_images
      image: windows-2025-enterprise
      version: "12.3"
    aws:
      type: ami
      id: "ami-0a1b2c3d4e5f60718"       # pinned; immutable
    gcp:
      type: image
      project: corp-image-prod
      family: windows-2025-ent
      name: windows-2025-ent-20260301
```

### 7.2 Selection

```
  selection = first catalogue entry where:
      entry.os_family        == request.os_family
   AND entry.approval_status == "approved"
   AND entry.expires_at      > as_of                      (P2: gate new selection)
   AND entry.revoked_at    is null                        (P1: absolute)
   AND entry.supports(request.provider)
   AND entry.classification >= environment.min_image_classification
   AND provider.region in configuration/regions/<region>.allowed_image_catalogues
   AND policy_allows(entry, request)                       (LEVEL 0 floor)

  no match  ->  IMAGE_NOT_FOUND, fatal, with the *reason* per criterion
                (e.g. "win-2025-enterprise excluded: region NRT allows
                 [ent-linux] only") — an actionable message, not "image not found"
```

Classification ordering (`internal` < `confidential` < `restricted`) lets an environment demand
a *higher* classification floor than the catalogue default, which is how data-residency and
classification policy is expressed without a bespoke rule per catalogue.

### 7.3 Pinning

```json
"image": { "catalog_id": "win-2025-enterprise", "provider": "azure",
           "type": "SharedImageVersion", "gallery": "org_images",
           "image": "windows-2025-enterprise", "version": "12.3",
           "baseline": "cis_windows_2025_1",
           "pinned_at": "2026-09-14T09:12:44Z", "catalog_version": "2026.09.1" }
```

Written to `context.json` once and **never re-resolved** within a run. This gives:

- **Reproducibility** — a build can be explained years later from the contract plus the pin.
- **Stability** — the image catalogue may move to `12.4` mid-build; run 47 still uses `12.3`.
- **Answerability** — "what image version is PAY-PROD-APP-AMS-001 running?" is answered by a
  cloud tag (`ImageVersion`), with no dependency on the current catalogue.

### 7.4 The two time-based gates, and why they differ

| Field | In-flight runs | New selections | Rationale |
|---|---|---|---|
| `expires_at` | **Allowed** (advisory warning) | Blocked | A routine catalogue rotation must not fail a 40-minute Windows build at minute 39 for a reason unrelated to the build |
| `revoked_at` | **Blocked** | Blocked | A security withdrawal is absolute. Continuing to build from a withdrawn image is the actual risk |

`revoked_at` is checked twice: at selection (resolver) and again in pre-flight
([request-lifecycle.md ](request-lifecycle.md#phase-4--pre-flight-validation-stage-validate-20)),
because a revocation can be published *after* a run resolved. This is the mitigation for
[R-07](enterprise-architecture.md#9-architecture-risk-register): an emergency image
withdrawal is a one-line catalogue edit plus a pre-flight check, **not** a code change or a
rollout.

### 7.5 AWS AMI handling

AMI ids are immutable but opaque, so a catalogue of them must either be maintained or resolved.
Both are supported, and which one is used is explicit:

| Mode | Catalogue form | Behaviour |
|---|---|---|
| **Pinned** (default, preferred) | `providers.aws.id: ami-…` | Fully deterministic, zero runtime cost. Requires the image pipeline to update the catalogue |
| **Tag query** | `providers.aws.tag_query: {Name: windows-2025-ent, Approval: approved}` | Resolved at selection time; the resolved AMI **and the query timestamp** are recorded in `context.json` |

Tag-query mode is a deliberate reproducibility trade-off, and the recorded resolution is what
makes it auditable rather than merely convenient. Azure Shared Image Versions and GCP image
names resolve to stable references, so neither needs it.

### 7.6 `sba_cloud_role` / `sba_image_role` — the closed dispatch map

```
  azure -> azure_vm        / azure_image
  aws   -> aws_ec2         / aws_image
  gcp   -> gcp_compute     / gcp_image
```

Two separate enums, because §9's single dynamic name is ambiguous about whether it refers to
the VM or the image resource ([C-13](architectural-decisions.md#2-requirement-conflict-register)). Both are hard-coded
maps inside the resolver; a value that is not a member is a resolver bug and the policy gate
fails the run before dispatch ([AD-08](architectural-decisions.md#ad-08-provider-abstraction-via-a-fixed-contract--role-allow-list)).

---

## 8. Tag Resolution — TagMapper

§24's 12 mandatory tags, mapped per provider. This is where
[C-02](architectural-decisions.md#2-requirement-conflict-register) is discharged.

### 8.1 Business metadata → provider shapes

```yaml
# configuration/clouds/gcp.yml
tagging:
  labels:                      # ≤63 chars/value, lowercase, indexed, queryable
    app:            "{application|lower}"
    env:            "{environment|lower}"
    role:           "{server_role|lower}"
    region:         "{region|lower}"
    sba_instance_id: "{naming.instances[].sba_instance_id}"
    sba_request_id: "{identity.request_id}"
    managed_by:     "ansible"
    lifecycle_stage:"{lifecycle.stage}"
  annotations:                 # full metadata, not indexed
    Application:          "{identity.application}"
    Environment:          "{identity.environment}"
    ServerRole:           "{identity.server_role}"
    Owner:                "{ownership.owner}"
    CostCenter:           "{ownership.cost_center}"
    BusinessUnit:         "{ownership.business_unit}"
    ManagedBy:            "Ansible"
    AutomationPlatform:   "SBA"
    ServiceNowRequest:    "{identity.request_id}"
    ChangeRequest:        "{identity.change_reference}"
    DataClassification:   "{classification.level}"
    Criticality:          "{classification.criticality}"
    CreatedBy:            "{identity.requested_by_display}"
    ImageCatalogId:       "{image.catalog_id}"
    ImageVersion:         "{image.version}"
    GitSha:               "{code.git_sha}"
    EeDigest:             "{code.ee_digest}"
    RunId:                "{identity.run_id}"
    CorrelationId:        "{identity.correlation_id}"
```

```yaml
# configuration/clouds/azure.yml
tagging:
  tags:                       # key ≤512, value ≤256, 50 max — all 12 fit directly
    Application: "{identity.application}"
    ... (all 12 mandatory, same keys as GCP annotations)
    ImageCatalogId: "{image.catalog_id}"
    ImageVersion: "{image.version}"
    GitSha: "{code.git_sha}"
    EeDigest: "{code.ee_digest}"
    SbaInstanceId: "{naming.instances[].sba_instance_id}"
    SbaRunId: "{identity.run_id}"
```

```yaml
# configuration/clouds/aws.yml
tagging:
  tags:                       # key ≤128, value ≤256, 50 max — all 12 fit directly
    Application: "{identity.application}"
    ... (all 12, same keys)
    SbaInstanceId: "{naming.instances[].sba_instance_id}"
```

### 8.2 The GCP constraints, restated because they drive the design

| Constraint | Consequence |
|---|---|
| Label key: ≤63 chars, **lowercase letters/digits/`-`/`_` only** | `ServiceNowRequest`, `CostCenter`, `DataClassification` are **invalid label keys** and must be snake_cased — which is why they are annotations |
| Label value: ≤63 chars | A UUIDv4 `sba_instance_id` (36) fits; a 20-field JSON blob would not |
| Max 64 labels per resource | Comfortable for 8 |
| **Labels can only be added/removed while the instance is STOPPED** | Metadata must be correct **at create time**. Retagging after provisioning is not an option on GCP |

That last row is the one that changes the architecture rather than just the tag set. Because
GCP cannot relabel a running instance, the *only* correct design is to compute complete,
provider-shaped metadata during resolution and pass it to create
([I-3](architectural-decisions.md#3-cross-cutting-invariants)). There is no "tag it later"
step, and a design that has one would work on Azure and AWS and silently fail on GCP.

### 8.3 Enforcement

Tag completeness is asserted **before** provisioning, not after:

```
  for each required tag in policies.enterprise.yml#required_tag_set:
      assert present in TagMapper(provider).output
      assert within the provider's key/value length limits
      assert the label-key character set on GCP
  violation  ->  TAG_MAPPING_INCOMPLETE  (fatal, VALIDATION_FAILED)

  plus a post-condition after create:
      read the tags back from the provider and compare to the intended set
      mismatch -> PROVISION_FAILED with TAG_WRITE_INCOMPLETE
```

Both halves are needed. The first catches a configuration error before any resource exists;
the second catches a provider-side failure (IAM denying a tag write, a quota on the tag API).
The second is easy to omit and is the reason cloud tags can silently diverge from the intended
metadata, which would break inventory, cost attribution and the audit trail simultaneously.

---

## 9. Pre-Flight Validation (Stage `validate`, §20)

Separate from the resolver because it needs read-only cloud credentials
([AD-22](architectural-decisions.md#ad-22-resolver-is-read-only-and-side-effect-free)).

```
  IDEMPOTENT   yes  — read-only
  CREDENTIALS  read-only cloud identity, scoped to describe/list/quota
  NETWORK      outbound to cloud APIs only; NO management-plane access to targets
  ORDER        after resolution, before any mutation
  COST         ~1-3 API calls per resource type, seconds not minutes
```

### 9.1 Check catalogue

| # | Check | Reads | Failure code | Retryable |
|---|---|---|---|---|
| 1 | Contract matches the schema, enums closed, `count` in bounds | local | `SCHEMA_INVALID` | no |
| 2 | Every catalogue level resolved to exactly one file | local | `NO_APPROVED_CONFIGURATION` | no |
| 3 | No precedence conflicts in the merged tree | local | `PRECEDENCE_CONFLICT` | no |
| 4 | Policy floor satisfied (§25 rules) | local | `POLICY_VIOLATION` | no |
| 5 | Tag set complete and within provider limits | local | `TAG_MAPPING_INCOMPLETE` | no |
| 6 | Image entry approved, not expired, not revoked | local | `IMAGE_NOT_APPROVED` / `IMAGE_EXPIRED` | no |
| 7 | Region available to the executing identity | cloud | `REGION_NOT_AVAILABLE` | no |
| 8 | Pinned image exists in the expected gallery/project | cloud | `IMAGE_NOT_FOUND` | no |
| 9 | Image **not revoked since resolution** (security gate) | cloud + catalogue | `IMAGE_REVOKED` | no |
| 10 | Subscription/project exists; identity has access | cloud | `SCOPE_NOT_ACCESSIBLE` | no |
| 11 | Resource group / project exists (or creation is permitted) | cloud | `PARENT_SCOPE_MISSING` | no |
| 12 | VNet/VPC exists; subnet belongs to it | cloud | `NETWORK_MISMATCH` | no |
| 13 | Subnet free IPs ≥ `count` | cloud | `SUBNET_IP_EXHAUSTED` | no |
| 14 | Security policy exists and is bound | cloud | `SECURITY_POLICY_MISSING` | no |
| 15 | Quota for the chosen size family is sufficient | cloud | `QUOTA_EXCEEDED` | no |
| 16 | Size is offered in the region | cloud | `SIZE_NOT_AVAILABLE_IN_REGION` | no |
| 17 | Short names free in the AD domain | AD | `NAME_TAKEN` | no |
| 18 | `change_reference` present for governed environments | local | `APPROVAL_FAILED` | no |
| 19 | Optional: change is in an approved/implementing state | ServiceNow | `APPROVAL_FAILED` | no |
| 20 | Optional: compliance attestation present and current for the image | local | `COMPLIANCE_MISSING` | no |
| 21 | Runner can reach the target management port on the target subnet | network probe | `RUNNER_NOT_REACHABLE` | **yes** |
| 22 | Request not currently blocked by an org-level freeze/maintenance | local | `CHANGE_FREEZE_ACTIVE` | no |

**Check 17 is the one that cannot be skipped on Windows.** A short-name collision in the AD
domain is only detectable by querying the domain, and it is the most likely cause of a Stage 4
failure — a failure that occurs *after* a full VM has been built. Moving the check to pre-flight
converts a 45-minute failure into a 20-second rejection. This is the concrete payoff of the
naming design in [AD-06](architectural-decisions.md#ad-06-two-name-model-short-netbios-name--long-fqdn).

**Check 22** is deliberately included even though it is not in §20: a change freeze is a routine
enterprise control, and if the platform ignores it, the freeze is only enforced by humans
remembering. Implementing it in the policy layer means the freeze is enforced
mechanically for automated requests as well.

### 9.2 Output

`result.validate.json` lists every check with its outcome, so a rejection is a report a
requester can act on, and a successful validation is evidence for an audit:

```json
{
  "stage": "validate",
  "status": "VALIDATION_FAILED",
  "checks_total": 22, "checks_passed": 21,
  "failures": [
    { "check": 13, "code": "SUBNET_IP_EXHAUSTED",
      "detail": "subnet snet-payments-prod-app has 1 free address, 2 requested",
      "actionable": "Reduce count to 1, or request a subnet range extension via the
                     network change process.",
      "retryable": false }
  ],
  "advisories": [
    { "code": "IMAGE_DEPRECATED", "detail": "catalog win-2025-enterprise is deprecated;
      replacement win-2025-enterprise-r2 is approved and will become mandatory on 2026-10-01" }
  ]
}
```

`actionable` is a required field. A validation failure that only reports *what* went wrong
generates a support ticket; one that says what to do instead closes itself.

---

## 10. Policy Gate

§25's twelve policy categories, expressed as data in `configuration/policies/`, evaluated after
resolution and before mutation. Rules are declarative; there is no policy code.

```yaml
# configuration/policies/production.yml
version: 1
applies_to: { environment: [PROD] }
floor: true                      # cannot be overridden by any level  [P2]
rules:
  - id: approved_clouds
    check: identity.provider in policy.approved_clouds
    on_violation: { code: POLICY_VIOLATION, retryable: false }

  - id: approved_regions
    check: regions[identity.region].allowed == true

  - id: change_reference_required
    check: identity.change_reference not empty
    severity: error

  - id: max_batch_serial
    check: lifecycle.serial <= 2
    message: "Production batches are limited to {max}; submit separate requests."

  - id: allowed_vm_families
    check: compute.size family in policy.allowed_vm_families

  - id: approved_images
    check: image.approval_status == 'approved' and image.revoked_at == null

  - id: require_backup
    check: backup.policy in policy.required_backup_policies
    auto_fix: { backup.policy: gold }     # a floor can also *raise* a value

  - id: require_monitoring
    check: monitoring.policy in policy.required_monitoring_policies
    auto_fix: { monitoring.policy: standard }

  - id: require_security_agents
    check: security.required_agents superset_of policy.minimum_security_agents
    auto_fix: { security.required_agents: union(...) }

  - id: required_tag_set
    check: tags superset_of policy.required_tag_set

  - id: network_restrictions
    check: network.private_only == true
    check: network.expose_public == false

  - id: naming_standards
    check: naming conforms_to policy.naming_patterns
```

Two design points worth stating:

**`auto_fix` on a policy floor.** Policies do not only reject; they can *raise* a value to the
minimum. A role that omits a backup policy in a governed environment gets `gold` applied
rather than a rejection, because the enterprise intent is unambiguous and a rejection here
teaches the requester nothing. Policies only ever tighten, never loosen — `auto_fix` moves a
value **toward** the floor, and an `auto_fix` that would loosen is rejected at policy-load
time as a misconfiguration.

**Failure before creation, always.** The gate runs before any mutation, so a policy violation
costs zero infrastructure and zero cloud spend. This is the whole point of separating
resolution (free) from pre-flight (cheap) from provisioning (expensive).

---

## 11. Failure Model

| Condition | Code | Terminal | Message quality |
|---|---|---|---|
| Enum not in the closed set | `UNSUPPORTED_ENUM_VALUE` | yes | "cloud 'ONPREM' is not supported. Supported: AZURE, AWS, GCP. Register the cloud in configuration/clouds/ first." |
| No catalogue file for a level | `NO_APPROVED_CONFIGURATION` | yes | "No application configuration for 'PAYMENTS'. Register it in configuration/applications/." |
| Same-level conflict | `PRECEDENCE_CONFLICT` | yes | Names both files and both values — a config bug, reported as a config bug |
| Policy floor violated | `POLICY_VIOLATION` | yes | Rule id, the offending value, the floor, and the remediation |
| Image unavailable | `IMAGE_NOT_FOUND` | yes | Per-criterion reason (expiry, region, classification, revocation) |
| Tag set incomplete | `TAG_MAPPING_INCOMPLETE` | yes | Which tags, which provider, which limit |
| Name exhausted / taken | `NAME_UNRESOLVABLE` / `NAME_TAKEN` | yes | The scope, the attempted names, and that a code allocation is needed |
| Quota / network | `QUOTA_EXCEEDED` / `SUBNET_IP_EXHAUSTED` | yes | Current vs requested, with the owning team |
| Resolver internal error | `RESOLVER_ERROR` | yes | Request id, catalog version, input hash — **never a stack trace to the requester**; the full trace goes to the platform log |

The last row is a security property as much as a UX one. A resolver exception can easily
contain a file path, a key name or a value from configuration; requester-facing messages are
built from a closed set of templates with parameter substitution, and the raw exception goes
only to the platform log. §21: "Do not expose raw secrets or sensitive infrastructure details
in error messages."

---

## 12. Resolver Interface

Three entry points, all returning the same document shape.

```bash
# 1. CLI — used by GHA, AAP, and by a developer at a terminal
scripts/resolve_configuration.py \
    --request run_contract.json \
    --catalog configuration/ \
    --as-of 2026-09-14T09:00:00Z \
    --out context.json \
    --report report.json

# 2. Ansible — a thin role, so a stage gets the resolved config as a fact.
#    No resolution logic in the role; it invokes (1) and asserts the exit code.
roles/platform/resolve_configuration/tasks/main.yml

# 3. Library — for a future HTTP API or a chatbot, without reimplementing anything
from sba_resolver import Resolver
result = Resolver(catalog=Path("configuration")).resolve(request, as_of=...)
```

Exit codes are meaningful, because every caller is a script:

| Code | Meaning |
|---|---|
| `0` | Resolved; `context.json` written |
| `2` | Schema validation failed |
| `3` | Precedence conflict |
| `4` | No approved configuration for the request |
| `5` | Policy violation |
| `6` | Image resolution failed |
| `7` | Name allocation failed |
| `8` | Tag mapping incomplete |
| `70` | Internal error (platform fault — page someone) |

---

## 13. Testing

| Level | What | Notes |
|---|---|---|
| **Golden files** | Every `(app, env, cloud, region, role, os)` combination in the catalogue ⇒ a checked-in expected `resolved_configuration.json` | The strongest possible test: any change in resolution behaviour is a visible diff that must be reviewed. Re-run on every catalogue change |
| **Precedence table** | One test per precedence rule P1-P7, including the same-level conflict case | |
| **Provenance** | Assert every leaf has a valid `provenance.source` that exists in the catalogue | Catches typos in config keys that would otherwise silently fall through to a default |
| **Closed enums** | Every enum rejects an unknown member | Property-based test over generated strings |
| **Purity** | `socket.socket` monkeypatched to raise; assert no exception in any resolver test | The mechanical enforcement of [AD-22](architectural-decisions.md#ad-22-resolver-is-read-only-and-side-effect-free) |
| **Determinism** | Resolve the same input 100× ⇒ byte-identical output | Catches dict-ordering and time-dependence bugs |
| **Naming** | Exhaustive: all 4 app codes × 3 env codes × 5 role codes × regions; assert ≤15, charset, uniqueness, and that a forced collision produces `NAME_UNRESOLVABLE` rather than a bad name | The [C-01](architectural-decisions.md#2-requirement-conflict-register) mitigation must be proven, not assumed |
| **Naming vs AD** | For every generated short name, assert the SAM name is valid and not reserved | A reserved name (e.g. `administrator`, `guest`, `krbtgt`) would fail at join, at minute 35 |
| **TagMapper per provider** | All 12 mandatory tags present; GCP keys lowercase and ≤63; GCP values ≤63; tag count within limits; **round-trip**: write to a real sandbox instance, read back, compare | The [C-02](architectural-decisions.md#2-requirement-conflict-register) mitigation must be proven against the real API |
| **Image selection** | Expiry boundary (exactly `as_of == expires_at`), revocation overrides expiry, classification floor, region allow-list, provider fallback absence | Boundary conditions are where catalogue logic actually breaks |
| **Policy** | Each rule has a positive and a negative fixture; `auto_fix` never loosens | |
| **Schema** | The resolved context validates against `schemas/run-context.schema.json` | |
| **Regression** | Catalogue change ⇒ golden files regenerate ⇒ diff is reviewed | The change-control point for configuration |

---

## 14. Performance

Non-production. The resolver is on the critical path of every request, so it must be fast
enough that nobody is tempted to skip it.

| Operation | Target | p95 |
|---|---|---|
| Catalogue load (≈40 files) | 30 ms | 80 ms |
| Merge + validate | 5 ms | 15 ms |
| Image selection (indexed) | 1 ms | 3 ms |
| Naming (pure computation) | <1 ms | 2 ms |
| Tag mapping | 1 ms | 3 ms |
| Policy evaluation (34 rules) | 5 ms | 15 ms |
| **Total resolve** | **~45 ms** | **~120 ms** |
| Sequence CAS (network) | 40 ms | 150 ms |
| **Total resolution phase** | **~90 ms** | **~300 ms** |

`p95 ~300 ms` against a build of 35-60 minutes is 0.01% of wall clock, and it is the phase
that decides whether the expensive part happens at all.

---

## 15. Extension

| Change | Touches | Existing resolution modified? |
|---|---|---|
| New application | `configuration/applications/<app>.yml` (+ golden file) | No |
| New region | `configuration/regions/<region>.yml` + `clouds/<cloud>.yml` `region_map` (+ golden file) | No |
| New server role | `configuration/server_roles/<role>.yml` | No |
| New image | `configuration/images/catalog.yml` | No |
| New policy rule | `configuration/policies/<env>.yml` | No |
| New cloud | `configuration/clouds/<cloud>.yml` + TagMapper case + closed-map entry + 2 roles | Resolver's map only |
| New OS family | `configuration/os/<family>.yml` + 1 baseline role | No |
| **New request field** | Contract schema + resolver input handling + policy + tests | The contract (deliberately, and additively — [AD-20](architectural-decisions.md#ad-20-additive-schema-versioning-only)) |

The last row is the only one that modifies existing behaviour, and it is the request contract —
so it is the one change that goes through a schema version bump and a compatibility review. That
is the correct place for friction: a new request field is the one thing that could re-open the
door to technical inputs ([I-1](architectural-decisions.md#3-cross-cutting-invariants)).

---

## 16. Next

- Request/response schemas: [../api/api-contract.md](../api/api-contract.md)
- Pre-flight and stage detail: [request-lifecycle.md](request-lifecycle.md)
- Naming, tagging and provider dispatch: [provider-abstraction.md](provider-abstraction.md)
- Role-level use of the resolved configuration: [role-dependency-model.md](role-dependency-model.md)
