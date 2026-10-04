# ServiceNow Trigger Contract — GCP VM Provisioning

**Status:** Phase 1 — GCP Only
**Version:** 1.0
**Last Updated:** 2026-10-05

---

## Overview

This document defines the contract between ServiceNow (Flow Designer / IntegrationHub) and the Server Build Automation platform for triggering GCP VM provisioning. The contract covers:

1. **Request Payload** — Fields sent from ServiceNow to trigger provisioning
2. **Authentication** — How ServiceNow authenticates to GitHub Actions or AAP
3. **Response Format** — JSON callback from platform to ServiceNow
4. **Error Handling** — Error codes and retry behavior

---

## 1. Request Payload

### 1.1 GitHub Actions Path (repository_dispatch)

**Endpoint:** `POST https://api.github.com/repos/{owner}/{repo}/dispatches`

**Headers:**
```http
Authorization: Bearer <github_app_installation_token>
Accept: application/vnd.github+json
Content-Type: application/json
```

**Body:**
```json
{
  "event_type": "provision_gcp",
  "client_payload": {
    "cloud": "gcp",
    "environment": "dev",
    "os_family": "rhel9",
    "app_tier": "web",
    "vm_count": 3,
    "requestor": "john.doe",
    "change_ticket": "CHG0012345",
    "expiry_date": "2027-12-31",
    "callback_url": "https://instance.service-now.com/api/sba/callback",
    "run_domain_join": true,
    "run_agent_install": true,
    "agent_type": "dynatrace",
    "agent_install_method": "package",
    "agent_config": {
      "tenant": "abc123",
      "api_key": "***",
      "policy": "default"
    }
  }
}
```

### 1.2 AAP Path (Job Template Launch)

**Endpoint:** `POST {aap_base_url}/api/controller/job_templates/{id}/launch/`

**Headers:**
```http
Authorization: Bearer <aap_oauth2_token>
Content-Type: application/json
```

**Body:**
```json
{
  "extra_vars": {
    "run_context_id": "01HQ8Z...RITM0012345"
  },
  "job_tags": [
    "sba:request_id=RITM0012345",
    "sba:environment=dev",
    "sba:correlation_id=0192f3a4-...",
    "sba:app=payments",
    "sba:stage=all"
  ],
  "limit": "dev,nonprod,prod"
}
```

> **Note:** AAP path uses `run_context_id` only. The full configuration is resolved by the platform and stored in the run-state store. See `docs/architecture/servicenow-aap.md` §3.

---

## 2. Payload Field Definitions

### 2.1 Required Fields (8 Variables — Provider Contract)

| Field | Type | Required | Validation | Description |
|---|---|---|---|---|
| `cloud` | string | ✅ | enum: `gcp` | Target cloud provider. Phase 1 only supports `gcp`. |
| `environment` | string | ✅ | enum: `dev`, `staging`, `prod` | Deployment environment. Maps to GCP project, network, subnet, SA. |
| `os_family` | string | ✅ | enum: `rhel9`, `ubuntu2204`, `windows2022` | OS family/version. Maps to GCP image family. |
| `app_tier` | string | ✅ | enum: `web`, `app`, `db` | Application tier. Maps to subnet, machine type, cost center. |
| `vm_count` | integer | ✅ | 1-20 | Number of VMs to provision. |
| `requestor` | string | ✅ | regex: `^[a-zA-Z0-9._-]{1,64}$` | ServiceNow user who requested the build. Used for `owner` label. |
| `change_ticket` | string | ✅ | regex: `^CHG[0-9]{7,}$` | ServiceNow change ticket number. Used for `change_ticket` label. |

### 2.2 Optional Fields

| Field | Type | Required | Validation | Description |
|---|---|---|---|---|
| `expiry_date` | string | ❌ | format: `YYYY-MM-DD` | Optional lifecycle expiry date. Used for `expiry` label. |
| `callback_url` | string | ❌ | format: URI | ServiceNow callback endpoint for async response. |
| `run_domain_join` | boolean | ❌ | default: `false` | Whether to run domain join after provision. |
| `run_agent_install` | boolean | ❌ | default: `false` | Whether to run agent install after provision. |

### 2.3 Domain Join Fields (Required if `run_domain_join=true`)

| Field | Type | Required | Description |
|---|---|---|---|
| `domain_controller` | string | ✅ | AD domain controller FQDN |
| `domain_realm` | string | ✅ | Kerberos realm (e.g., EXAMPLE.COM) |
| `domain_ou` | string | ✅ | OU path for computer object |
| `domain_join_user` | string | ✅ | Account with join permissions |
| `domain_join_password` | string | ✅ | Credential for join account (sensitive) |

### 2.4 Agent Install Fields (Required if `run_agent_install=true`)

| Field | Type | Required | Description |
|---|---|---|---|
| `agent_type` | string | ✅ | enum: `dynatrace`, `datadog`, `crowdstrike`, `other` |
| `agent_install_method` | string | ✅ | enum: `package`, `script`, `container` |
| `agent_config` | object | ✅ | Agent-specific config (tenant, API key, policy, etc.) |

---

## 3. Authentication

### 3.1 GitHub Actions (ServiceNow → GitHub)

**Method:** GitHub App Installation Token

1. Create GitHub App in organization with `repository_dispatch` permission
2. Install app on target repository
3. ServiceNow stores: `app_id`, `private_key`, `installation_id`
4. ServiceNow generates JWT → exchanges for installation token → calls `repository_dispatch`

**Token Generation (ServiceNow side):**
```javascript
// Pseudo-code for ServiceNow script
const jwt = generateJWT({
  iat: Math.floor(Date.now() / 1000),
  exp: Math.floor(Date.now() / 1000) + 600, // 10 min
  iss: APP_ID
}, PRIVATE_KEY);

const installationToken = await fetch(
  `https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens`,
  { method: 'POST', headers: { Authorization: `Bearer ${jwt}` } }
).then(r => r.json()).then(d => d.token);
```

### 3.2 AAP (ServiceNow → AAP)

**Method:** OAuth2 Client Credentials Grant

1. Create OAuth2 application in AAP with `write:job_template` scope
2. ServiceNow stores: `client_id`, `client_secret`, `aap_base_url`
3. ServiceNow requests token → calls job template launch

**Token Generation (ServiceNow side):**
```javascript
// Pseudo-code for ServiceNow script
const tokenResponse = await fetch(
  `${AAP_BASE_URL}/api/o/token/`,
  {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'client_credentials',
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
      scope: 'write:job_template'
    })
  }
).then(r => r.json());

const accessToken = tokenResponse.access_token;
```

---

## 4. Response Format (Callback)

### 4.1 Success Response

**POST** to `callback_url` (if provided in request)

**Headers:**
```http
Content-Type: application/json
Authorization: Bearer <servicenow_callback_token>
```

**Body:**
```json
{
  "status": "SUCCESS",
  "instance_id": "12345678-1234-1234-1234-123456789012",
  "instance_name": "sba-dev-web-r9-001",
  "private_ip": "10.0.1.5",
  "public_ip": "",
  "fqdn": "sba-dev-web-r9-001.internal",
  "zone": "us-central1-a",
  "region": "us-central1",
  "provisioned_at": "2026-10-05T14:30:00Z",
  "provisioned_by": "github-actions",
  "run_context_id": "01HQ8Z...RITM0012345",
  "change_ticket": "CHG0012345",
  "requestor": "john.doe",
  "domain_join": {
    "status": "SUCCESS",
    "completed_at": "2026-10-05T14:45:00Z"
  },
  "agent_install": {
    "status": "SUCCESS",
    "agent_type": "dynatrace",
    "completed_at": "2026-10-05T14:50:00Z"
  }
}
```

### 4.2 Failure Response

```json
{
  "status": "FAILED",
  "error_code": "QUOTA_EXCEEDED",
  "error_message": "Insufficient quota for instances in region us-central1",
  "instance_id": "12345678-1234-1234-1234-123456789012",
  "instance_name": "sba-dev-web-r9-001",
  "failed_at": "2026-10-05T14:30:00Z",
  "failed_stage": "provision",
  "run_context_id": "01HQ8Z...RITM0012345",
  "change_ticket": "CHG0012345",
  "requestor": "john.doe",
  "retryable": true,
  "retry_after_seconds": 300
}
```

### 4.3 Error Codes

| Code | HTTP Status | Retryable | Description |
|---|---|---|---|
| `VALIDATION_ERROR` | 400 | No | Input validation failed (invalid enum, missing field, etc.) |
| `AUTHENTICATION_FAILED` | 401 | No | GitHub App token or AAP OAuth token invalid/expired |
| `AUTHORIZATION_FAILED` | 403 | No | Token lacks required permissions |
| `QUOTA_EXCEEDED` | 429 | Yes | GCP quota exceeded (instances, disks, IPs) |
| `RESOURCE_NOT_FOUND` | 404 | No | Image family, subnet, or service account not found |
| `IMMUTABLE_MISMATCH` | 409 | No | Existing instance has different immutable attributes |
| `AMBIGUOUS_RESOURCE` | 409 | No | Multiple instances found with same `sba_instance_id` label |
| `PROVISION_TIMEOUT` | 504 | Yes | Instance did not reach RUNNING state within timeout |
| `DOMAIN_JOIN_FAILED` | 500 | Yes | Domain join operation failed |
| `AGENT_INSTALL_FAILED` | 500 | Yes | Agent installation failed |
| `INTERNAL_ERROR` | 500 | Yes | Unexpected platform error |

---

## 5. Idempotency

### 5.1 Request Fingerprint

ServiceNow **must** include a `fingerprint` field (or use `change_ticket` + `requestor` + `environment` + `os_family` + `app_tier` + `vm_count`) to enable idempotency.

The platform computes a SHA256 hash of the normalized request payload and checks against the run-state store:

- **Identical fingerprint + SUCCESS status** → Returns existing result with `duplicate: true`
- **Identical fingerprint + IN_PROGRESS** → Returns `QUEUED` with existing `run_id`
- **Identical fingerprint + FAILED** → Allows retry (new run)
- **Different fingerprint** → Creates new run

### 5.2 Retry Behavior

| Scenario | Behavior |
|---|---|
| Network timeout calling dispatch | ServiceNow retries with exponential backoff (max 3) |
| Platform returns `retryable: true` | ServiceNow retries after `retry_after_seconds` |
| Platform returns `retryable: false` | ServiceNow alerts operator, does not retry |
| Duplicate request (same fingerprint) | Platform returns existing result immediately |

---

## 6. Status Polling (Alternative to Callback)

If `callback_url` is not provided, ServiceNow can poll for status:

### 6.1 GitHub Actions Path

**Endpoint:** `GET https://api.github.com/repos/{owner}/{repo}/actions/runs/{run_id}`

**Response:** Check `conclusion` field (`success`, `failure`, `cancelled`)

### 6.2 AAP Path

**Endpoint:** `GET {aap_base_url}/api/controller/unified_jobs/{job_id}/`

**Response:**
```json
{
  "id": 4821,
  "status": "successful",
  "finished": "2026-10-05T14:30:00Z",
  "elapsed": 180.5,
  "url": "https://aap.example.com/api/controller/jobs/4821/"
}
```

**Status Mapping:**
| AAP Status | Platform Status |
|---|---|
| `pending`, `waiting`, `scheduled` | `QUEUED` |
| `running` | `IN_PROGRESS` |
| `successful` | `SUCCESS` (verify via artifact) |
| `failed`, `error`, `canceled` | `FAILED` / `CANCELLED` |
| `never ran` | `MANUAL_ATTENTION` |

---

## 7. JSON Schema (Request Validation)

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "ServiceNow Provision Request",
  "type": "object",
  "required": ["cloud", "environment", "os_family", "app_tier", "vm_count", "requestor", "change_ticket"],
  "properties": {
    "cloud": { "type": "string", "enum": ["gcp"] },
    "environment": { "type": "string", "enum": ["dev", "staging", "prod"] },
    "os_family": { "type": "string", "enum": ["rhel9", "ubuntu2204", "windows2022"] },
    "app_tier": { "type": "string", "enum": ["web", "app", "db"] },
    "vm_count": { "type": "integer", "minimum": 1, "maximum": 20 },
    "requestor": { "type": "string", "pattern": "^[a-zA-Z0-9._-]{1,64}$" },
    "change_ticket": { "type": "string", "pattern": "^CHG[0-9]{7,}$" },
    "expiry_date": { "type": "string", "format": "date" },
    "callback_url": { "type": "string", "format": "uri" },
    "run_domain_join": { "type": "boolean", "default": false },
    "run_agent_install": { "type": "boolean", "default": false },
    "domain_controller": { "type": "string" },
    "domain_realm": { "type": "string" },
    "domain_ou": { "type": "string" },
    "domain_join_user": { "type": "string" },
    "domain_join_password": { "type": "string" },
    "agent_type": { "type": "string", "enum": ["dynatrace", "datadog", "crowdstrike", "other"] },
    "agent_install_method": { "type": "string", "enum": ["package", "script", "container"] },
    "agent_config": { "type": "object" }
  },
  "dependencies": {
    "run_domain_join": ["domain_controller", "domain_realm", "domain_ou", "domain_join_user", "domain_join_password"],
    "run_agent_install": ["agent_type", "agent_install_method", "agent_config"]
  }
}
```

---

## 8. Example ServiceNow Flow Designer Action

### 8.1 Inputs (Flow Designer Action Designer)

| Input | Type | Required | Maps To |
|---|---|---|---|
| Cloud Provider | Choice | Yes | `cloud` |
| Environment | Choice | Yes | `environment` |
| OS Family | Choice | Yes | `os_family` |
| App Tier | Choice | Yes | `app_tier` |
| VM Count | Integer | Yes | `vm_count` |
| Requestor | String | Yes | `requestor` |
| Change Ticket | String | Yes | `change_ticket` |
| Expiry Date | Date | No | `expiry_date` |
| Run Domain Join | Boolean | No | `run_domain_join` |
| Domain Controller | String | Conditional | `domain_controller` |
| Domain Realm | String | Conditional | `domain_realm` |
| Domain OU | String | Conditional | `domain_ou` |
| Domain Join User | String | Conditional | `domain_join_user` |
| Domain Join Password | Password | Conditional | `domain_join_password` |
| Run Agent Install | Boolean | No | `run_agent_install` |
| Agent Type | Choice | Conditional | `agent_type` |
| Agent Install Method | Choice | Conditional | `agent_install_method` |
| Agent Config | JSON | Conditional | `agent_config` |
| Callback URL | String | No | `callback_url` |

### 8.2 Outputs (Flow Designer Action Designer)

| Output | Type | Description |
|---|---|---|
| Status | String | `SUCCESS`, `FAILED`, `QUEUED`, `IN_PROGRESS` |
| Instance ID | String | Unique provisioning run identifier |
| Instance Name | String | Generated VM name |
| Private IP | String | VM private IP address |
| Public IP | String | VM public IP (if any) |
| FQDN | String | Fully qualified domain name |
| Error Code | String | Error code if failed |
| Error Message | String | Human-readable error message |

---

## 9. Security Considerations

1. **No secrets in payload** — Credentials (domain join password, agent API keys) are passed as separate fields, not in `agent_config` plaintext. Use ServiceNow credential store references.
2. **Callback authentication** — Platform calls back with `Authorization: Bearer <token>`. ServiceNow validates token.
3. **Token rotation** — GitHub App tokens and AAP OAuth tokens must be rotated per policy (90 days).
4. **Audit logging** — All dispatch calls logged in GitHub Actions / AAP event stream with requestor identity.
5. **Least privilege** — GitHub App only needs `repository_dispatch`; AAP OAuth app only needs `write:job_template` on specific template.

---

## 10. Testing the Contract

### 10.1 Unit Tests (ServiceNow Side)
- Validate payload against JSON schema before dispatch
- Verify token generation works
- Verify callback signature verification works

### 10.2 Integration Tests (Platform Side)
- `curl` repository_dispatch with valid payload → expect 202 + callback
- `curl` repository_dispatch with invalid payload → expect 400 + error code
- AAP launch with valid `run_context_id` → expect 201 + job URL
- AAP launch with invalid `run_context_id` → expect 404

### 10.3 Contract Tests (CI)
- Schema validation in CI for both request and response
- Example payloads in `tests/fixtures/servicenow/` validated against schema

---

## 11. Versioning

| Version | Date | Changes |
|---|---|---|
| 1.0 | 2026-10-05 | Initial contract for Phase 1 GCP-only |

**Breaking changes** require major version bump and coordinated deployment with ServiceNow team.