# Project: Multi-Cloud Server Build Automation Platform

## Role

Act as a **Principal DevSecOps, Application Automation, Cloud Platform and Ansible Architect**.

Design and implement an enterprise-grade **Multi-Cloud Server Build Automation Platform** using:

* Ansible
* Ansible Automation Platform (AAP) / Automation Controller
* GitHub Actions
* ServiceNow
* Azure
* AWS
* GCP
* Existing approved OS image repositories
* Enterprise secret management
* Enterprise CMDB / inventory
* Git-based source control

The platform must support **Windows and Linux server provisioning** across Azure, AWS and GCP.

The solution must be designed for enterprise production use, security, auditability, idempotency, scalability and reusability.

---

# 1. Business Objective

Build a reusable Server Build Automation Platform where:

1. A user raises a ServiceNow request.
2. The user provides only the minimum required business inputs.
3. The platform derives as many technical parameters as possible automatically.
4. ServiceNow validates/approves the request.
5. ServiceNow invokes either:

   * GitHub Actions API
   * Ansible Automation Platform API
6. The automation determines the required cloud/server configuration.
7. An existing approved OS image is selected from the organization's image repository.
8. The server/VM is provisioned.
9. OS build/configuration is executed using Ansible.
10. Post-build activities are executed separately, for example:

    * Domain join
    * Monitoring agent installation
    * Security agent installation
    * Backup agent installation
    * Vulnerability/security tooling
    * CMDB registration/update
    * DNS registration
    * Load balancer registration
    * Application onboarding
11. ServiceNow is updated with:

    * Request status
    * Automation status
    * Server details
    * IP/DNS
    * Cloud resource ID
    * Image version
    * Build result
    * Post-build result
    * Failure information
    * Automation/job URL
12. Complete audit history must be maintained.

The platform must support both:

* OS provisioning executed through GitHub Actions
* OS provisioning executed through AAP

The same Ansible automation content must be reusable from both execution paths.

---

# 2. Important Design Principle

Do NOT make ServiceNow or the end user provide every infrastructure variable.

Avoid requests such as:

* VM size
* subnet ID
* VPC ID
* security group
* image ID
* disk type
* disk size
* DNS server
* domain controller
* OU
* monitoring configuration
* cloud credentials
* region-specific technical values

Instead implement a **configuration-driven model**.

The user should ideally provide only:

```yaml
business_application
environment
cloud
region
os
server_role
server_count
requested_by
change_reference
```

Even these should be minimized where possible.

The platform should derive technical values from approved configuration.

Example:

```text
ServiceNow Request
       |
       v
Application = Payments
Environment = PROD
Server Role = Application
OS = Windows
Cloud = Azure
Region = AMS
       |
       v
Configuration Resolver
       |
       +--> Azure subscription
       +--> Resource group
       +--> VNet
       +--> Subnet
       +--> VM size
       +--> Security policy
       +--> Image
       +--> Disk policy
       +--> Naming convention
       +--> Backup policy
       +--> Monitoring policy
       +--> Domain/OU
       |
       v
Ansible
```

---

# 3. Architecture

Design the platform using these logical layers:

```text
                         +----------------------+
                         |      ServiceNow      |
                         | Catalog / RITM /     |
                         | Approval / CMDB      |
                         +----------+-----------+
                                    |
                                    | API
                                    v
                         +----------------------+
                         | Automation Gateway   |
                         | / Orchestration      |
                         +----------+-----------+
                                    |
                     +--------------+--------------+
                     |                             |
                     v                             v
             +---------------+             +---------------+
             | GitHub Actions|             | AAP /         |
             |               |             | Controller    |
             +-------+-------+             +-------+-------+
                     |                             |
                     +--------------+--------------+
                                    |
                                    v
                         +----------------------+
                         | Ansible Automation   |
                         | Repository           |
                         +----------+-----------+
                                    |
                  +-----------------+------------------+
                  |                 |                  |
                  v                 v                  v
              Azure               AWS                GCP
                  |                 |                  |
                  +-----------------+------------------+
                                    |
                                    v
                         +----------------------+
                         | Approved OS Images   |
                         | Image Repository     |
                         +----------------------+

                                    |
                                    v
                         +----------------------+
                         | Post Build Automation|
                         +----------+-----------+
                                    |
              +---------------------+--------------------+
              |          |           |        |         |
              v          v           v        v         v
           Domain      Agents      DNS      Backup     CMDB
```

---

# 4. Repository Architecture

Follow the official Ansible project structure and adapt it for enterprise multi-cloud automation.

Use a structure similar to:

```text
server-build-automation/
│
├── ansible.cfg
├── requirements.yml
├── galaxy.yml
├── README.md
├── CHANGELOG.md
├── Makefile
│
├── inventories/
│   │
│   ├── dev/
│   │   ├── hosts.yml
│   │   ├── group_vars/
│   │   │   ├── all/
│   │   │   ├── azure/
│   │   │   ├── aws/
│   │   │   ├── gcp/
│   │   │   ├── linux/
│   │   │   └── windows/
│   │   └── host_vars/
│   │
│   ├── nonprod/
│   │   ├── hosts.yml
│   │   ├── group_vars/
│   │   └── host_vars/
│   │
│   └── prod/
│       ├── hosts.yml
│       ├── group_vars/
│       └── host_vars/
│
├── playbooks/
│   │
│   ├── server_build.yml
│   ├── server_destroy.yml
│   ├── server_validate.yml
│   │
│   ├── infrastructure/
│   │   ├── provision.yml
│   │   ├── validate.yml
│   │   └── destroy.yml
│   │
│   ├── os/
│   │   ├── linux.yml
│   │   └── windows.yml
│   │
│   └── post_build/
│       ├── domain_join.yml
│       ├── monitoring.yml
│       ├── security_agents.yml
│       ├── backup.yml
│       ├── dns.yml
│       └── cmdb.yml
│
├── roles/
│   │
│   ├── cloud/
│   │   ├── azure_vm/
│   │   ├── aws_ec2/
│   │   └── gcp_compute/
│   │
│   ├── image/
│   │   ├── azure_image/
│   │   ├── aws_image/
│   │   └── gcp_image/
│   │
│   ├── os/
│   │   ├── linux_baseline/
│   │   └── windows_baseline/
│   │
│   ├── security/
│   │   ├── cis_linux/
│   │   ├── cis_windows/
│   │   ├── security_agent/
│   │   └── vulnerability_agent/
│   │
│   ├── domain/
│   │   ├── linux_domain_join/
│   │   └── windows_domain_join/
│   │
│   ├── monitoring/
│   │   └── monitoring_agent/
│   │
│   ├── backup/
│   │   └── backup_agent/
│   │
│   ├── dns/
│   │   └── dns_registration/
│   │
│   └── cmdb/
│       └── servicenow_cmdb/
│
├── collections/
│
├── vars/
│   ├── global/
│   ├── azure/
│   ├── aws/
│   └── gcp/
│
├── schemas/
│   ├── server_request.schema.json
│   ├── resolved_configuration.schema.json
│   └── build_result.schema.json
│
├── configuration/
│   │
│   ├── environments/
│   │   ├── dev.yml
│   │   ├── nonprod.yml
│   │   └── prod.yml
│   │
│   ├── clouds/
│   │   ├── azure.yml
│   │   ├── aws.yml
│   │   └── gcp.yml
│   │
│   ├── server_roles/
│   │   ├── web.yml
│   │   ├── application.yml
│   │   ├── database.yml
│   │   └── middleware.yml
│   │
│   └── os/
│       ├── windows.yml
│       └── linux.yml
│
├── automation/
│   ├── github/
│   │   └── workflows/
│   │       ├── server-build.yml
│   │       ├── server-destroy.yml
│   │       ├── post-build.yml
│   │       └── validate.yml
│   │
│   └── aap/
│       ├── job_templates/
│       ├── workflow_templates/
│       └── surveys/
│
├── scripts/
│   ├── validate_request.py
│   ├── resolve_configuration.py
│   ├── validate_environment.py
│   └── generate_inventory.py
│
├── tests/
│   ├── unit/
│   ├── molecule/
│   └── integration/
│
└── docs/
    ├── architecture.md
    ├── security.md
    ├── onboarding.md
    ├── serviceNow-integration.md
    ├── github-actions.md
    ├── aap.md
    └── operations.md
```

Use the official Ansible recommendations as the foundation: roles for reusable functionality, environment separation, group/host variables, function-oriented playbooks, tags, dynamic inventory where appropriate, and source control.

---

# 5. Separate Provisioning From Post-Build

This is a mandatory architecture principle.

Do NOT create one giant playbook.

Use separate lifecycle stages:

```text
Stage 1
Infrastructure Provisioning
        |
        v
Stage 2
OS Configuration
        |
        v
Stage 3
Validation
        |
        v
Stage 4
Domain Join
        |
        v
Stage 5
Monitoring/Security/Backup Agents
        |
        v
Stage 6
DNS
        |
        v
Stage 7
CMDB
        |
        v
Stage 8
Application Onboarding
```

Each stage must be independently executable.

For example:

```bash
server-build
os-config
post-build
domain-join
install-agents
cmdb-update
```

This allows ServiceNow to trigger individual stages.

---

# 6. Input Contract

Create a canonical JSON request:

```json
{
  "request_id": "RITM0012345",
  "application": "PAYMENTS",
  "environment": "PROD",
  "cloud": "AZURE",
  "region": "AMS",
  "server_role": "APPLICATION",
  "os": "WINDOWS",
  "count": 2,
  "requested_by": "user",
  "change_reference": "CHG0012345"
}
```

Do NOT allow arbitrary infrastructure variables from ServiceNow.

Instead create:

```text
Request
   |
   v
Schema Validation
   |
   v
Configuration Resolver
   |
   v
Resolved Configuration
```

Example:

```json
{
  "cloud": "azure",
  "subscription": "production-subscription",
  "resource_group": "rg-payments-prod",
  "region": "westeurope",
  "vm_size": "Standard_D4s_v6",
  "subnet": "payments-prod",
  "image": "windows-2025-v12",
  "disk_policy": "enterprise-standard",
  "backup_policy": "gold",
  "monitoring_policy": "standard",
  "security_policy": "enterprise",
  "domain_ou": "OU=Servers,OU=Payments,DC=example,DC=com"
}
```

The resolved configuration must be generated automatically.

---

# 7. Configuration Resolution

Implement a dedicated configuration resolver.

Resolution hierarchy:

```text
ServiceNow request
       |
       v
Application configuration
       |
       v
Environment configuration
       |
       v
Cloud configuration
       |
       v
Region configuration
       |
       v
Server-role configuration
       |
       v
OS configuration
       |
       v
Enterprise policy
       |
       v
Final resolved configuration
```

The resolver must detect conflicts and fail safely.

Example:

```text
PROD + AWS + AMS + Windows + Application
```

automatically resolves:

```text
AWS account
VPC
Subnet
AMI
Instance type
IAM profile
Security groups
EBS policy
Backup
Monitoring
Domain
DNS
Naming convention
Tags
```

---

# 8. Image Strategy

Assume OS images already exist.

Do NOT build OS images inside this project.

The project must consume approved images.

Create an abstraction:

```yaml
image:
  provider: azure
  family: windows
  version: approved
  classification: enterprise
```

The automation should resolve the actual image ID/version.

Never allow a normal requester to provide an arbitrary image ID for production.

Implement:

```text
Image Family
Image Version
Approval Status
OS
Architecture
Patch Level
Security Baseline
Creation Date
Expiration Date
```

Only approved images may be used.

---

# 9. Cloud Abstraction

Do not put Azure/AWS/GCP-specific logic throughout the playbooks.

Use a common interface:

```text
provision_server()
validate_server()
destroy_server()
get_server()
```

Then implement provider-specific roles:

```text
azure_vm
aws_ec2
gcp_compute
```

The common orchestration determines the provider.

Example:

```yaml
- name: Provision server
  include_role:
    name: "cloud/{{ cloud_provider }}_{{ resource_type }}"
```

Prefer clean provider abstraction over excessive Jinja complexity.

---

# 10. Dynamic Inventory

Use dynamic inventory where practical.

Examples:

```text
Azure inventory
AWS inventory
GCP inventory
```

Do not maintain large static inventories of ephemeral cloud servers.

After provisioning:

```text
Cloud
  |
  v
Dynamic Inventory
  |
  v
Ansible
```

Use tags/labels such as:

```text
application
environment
server_role
owner
cost_center
managed_by
request_id
compliance
```

---

# 11. GitHub Actions

Create reusable workflows.

Example:

```text
.github/workflows/
    server-build.yml
    server-destroy.yml
    os-config.yml
    post-build.yml
    validate.yml
```

ServiceNow should call a controlled GitHub Actions workflow.

Do not expose arbitrary shell/Ansible commands through ServiceNow.

Use workflow inputs such as:

```yaml
request_id
environment
cloud
region
server_role
os
count
```

Validate every input.

Use GitHub Environments:

```text
dev
nonprod
prod
```

Use protected environments for production.

Use OIDC instead of long-lived cloud credentials wherever supported. GitHub specifically recommends OIDC for Azure/AWS/GCP authentication so workflows can use short-lived credentials rather than persistent cloud secrets.

Minimum workflow permissions:

```yaml
permissions:
  contents: read
  id-token: write
```

Do not use:

```yaml
permissions: write-all
```

---

# 12. AAP Integration

Support AAP as an alternative execution engine.

Architecture:

```text
ServiceNow
    |
    +----> GitHub Actions
    |
    +----> AAP API
```

The same Git repository and Ansible content should be used.

AAP should use:

* Projects
* Job Templates
* Workflow Templates
* Credentials
* Execution Environments
* RBAC
* Surveys only where absolutely necessary

Do not duplicate automation logic between GitHub and AAP.

AAP credentials must not be exposed to requesters. Automation Controller is designed to allow teams/users to use credentials without exposing the underlying secret values.

---

# 13. AAP Workflow

Design an AAP workflow:

```text
START
 |
 v
Validate Request
 |
 v
Resolve Configuration
 |
 v
Policy Check
 |
 v
Provision Infrastructure
 |
 v
Wait for Server
 |
 v
OS Configuration
 |
 v
Validation
 |
 +----FAIL----> Failure Handler
 |
 v
POST BUILD
 |
 +--> Domain Join
 |
 +--> Monitoring
 |
 +--> Security
 |
 +--> Backup
 |
 +--> DNS
 |
 +--> CMDB
 |
 v
SUCCESS
```

Every stage should have clear success/failure outputs.

---

# 14. ServiceNow Integration

Create a clean API contract.

ServiceNow should send:

```json
{
  "request_id": "RITM0012345",
  "application": "PAYMENTS",
  "environment": "PROD",
  "cloud": "AZURE",
  "region": "AMS",
  "server_role": "APPLICATION",
  "os": "WINDOWS",
  "count": 2
}
```

The automation platform returns:

```json
{
  "request_id": "RITM0012345",
  "status": "STARTED",
  "execution_engine": "AAP",
  "execution_id": "123456",
  "correlation_id": "abc-123"
}
```

Final result:

```json
{
  "request_id": "RITM0012345",
  "status": "SUCCESS",
  "servers": [
    {
      "hostname": "PAY-APP-001",
      "ip": "10.10.10.10",
      "cloud_resource_id": "..."
    }
  ],
  "image_version": "windows-2025-v12",
  "build_duration": 780
}
```

Implement idempotency using:

```text
request_id
change_reference
correlation_id
```

A repeated ServiceNow request must not accidentally create duplicate infrastructure.

---

# 15. Security Requirements

Security is a first-class requirement.

Implement:

### Secrets

Never store:

```text
passwords
API keys
private keys
cloud client secrets
domain credentials
tokens
```

in GitHub repository source code.

Use:

* AAP Credentials
* Enterprise Secret Manager
* Cloud-native identity
* GitHub OIDC
* Ansible Vault only where appropriate

Ansible Vault protects encrypted data at rest, but decrypted secrets still need careful handling, including `no_log` where required.

### Identity

Prefer:

```text
OIDC
Managed Identity
IAM Roles
Workload Identity
Federated Identity
```

over static credentials.

### Least privilege

Create separate identities for:

```text
GitHub
AAP
Azure
AWS
GCP
ServiceNow
CMDB
DNS
Domain Join
```

Do not use one enterprise superuser credential.

### Logging

Never log:

```text
password
token
secret
private key
```

Use:

```yaml
no_log: true
```

where necessary.

---

# 16. Supply Chain Security

Implement:

```text
pre-commit
ansible-lint
yamllint
gitleaks
checkov
trivy
semgrep
bandit
shellcheck
terraform fmt/validate
```

where applicable.

Run security checks before merge.

GitHub Actions must include:

```text
SAST
Secret scanning
Dependency scanning
IaC scanning
Ansible linting
YAML validation
```

Do not allow deployment from a branch that has failed mandatory security checks.

---

# 17. Ansible Quality Standards

Use:

```yaml
ansible.builtin.*
```

fully qualified collection names.

Always:

* Name plays
* Name tasks
* Define state
* Prefer idempotent modules
* Avoid shell/command unless necessary
* Register meaningful results
* Use handlers
* Use tags
* Use check mode where possible
* Use diff carefully
* Validate variables
* Fail early on invalid configuration
* Avoid hard-coded infrastructure values

Follow Ansible's documented guidance around fully qualified collection names, naming, state declaration, dynamic inventory, staging, batching and Execution Environments.

---

# 18. Execution Environment

Create an Ansible Execution Environment.

Example:

```text
execution-environment/
    execution-environment.yml
    requirements.yml
    requirements.txt
    bindep.txt
```

The EE should contain:

```text
ansible-core
Azure collections
AWS collections
GCP collections
Windows collections
community.general
Python dependencies
Cloud SDK dependencies
Security tooling
```

Pin versions.

Do not rely on:

```text
latest
```

for production dependencies.

---

# 19. Idempotency

Every role must be safe to execute multiple times.

Example:

```text
Run #1
CREATE VM

Run #2
DETECT VM EXISTS
NO DUPLICATE VM

Run #3
VALIDATE CONFIGURATION
NO UNNECESSARY CHANGE
```

The same principle applies to:

* Domain join
* DNS
* Agents
* CMDB
* Firewall rules
* Disks
* Tags
* Monitoring
* Backup

---

# 20. Validation

Before provisioning:

```text
Schema validation
Cloud validation
Policy validation
Quota validation
Image validation
Naming validation
Network validation
Security validation
Approval validation
```

After provisioning:

```text
VM exists
IP available
DNS works
OS reachable
WinRM/SSH works
OS version correct
Image version correct
Disk configuration correct
Security baseline correct
Required agents installed
CMDB updated
```

---

# 21. Failure Handling

Implement a standard result model:

```yaml
status:
  SUCCESS
  FAILED
  PARTIAL
  CANCELLED
  VALIDATION_FAILED
  APPROVAL_FAILED
```

Every stage must return structured information.

Example:

```json
{
  "stage": "domain_join",
  "status": "FAILED",
  "error_code": "DOMAIN_JOIN_TIMEOUT",
  "retryable": true,
  "message": "Domain controller was unreachable"
}
```

Do not expose raw secrets or sensitive infrastructure details in error messages.

---

# 22. Retry Strategy

Implement retries only for transient failures.

Examples:

```text
Cloud API timeout
Network unavailable
Server boot not complete
WinRM not ready
SSH not ready
DNS propagation
```

Do not retry:

```text
Invalid configuration
Unauthorized
Policy violation
Invalid image
Quota exceeded
Approval missing
```

Use exponential backoff.

---

# 23. Naming Convention

Create a centralized naming engine.

Example:

```text
<application>-<environment>-<role>-<region>-<sequence>
```

Example:

```text
pay-prod-app-ams-001
pay-prod-app-ams-002
```

Do not allow users to override naming standards unless explicitly approved.

---

# 24. Tagging

Mandatory cloud tags:

```yaml
Application:
Environment:
ServerRole:
Owner:
CostCenter:
BusinessUnit:
ManagedBy: Ansible
AutomationPlatform:
ServiceNowRequest:
ChangeRequest:
DataClassification:
Criticality:
CreatedBy:
```

Cloud-specific tagging/labeling must be implemented consistently.

---

# 25. Policy as Code

Create policies for:

```text
Approved clouds
Approved regions
Approved OS versions
Approved images
Allowed VM sizes
Required tags
Required backup
Required monitoring
Required security agents
Production restrictions
Network restrictions
Naming standards
```

Reject non-compliant requests before infrastructure creation.

---

# 26. Testing Strategy

Implement:

```text
YAML validation
ansible-lint
Molecule
Unit tests
Integration tests
Cloud sandbox tests
Security tests
End-to-end ServiceNow tests
```

Pipeline:

```text
Pull Request
    |
    v
Lint
    |
    v
Security Scan
    |
    v
Unit Test
    |
    v
Molecule
    |
    v
Integration
    |
    v
Approval
    |
    v
Production
```

---

# 27. Git Branching

Use:

```text
main
feature/*
bugfix/*
release/*
```

Production deployment must originate from controlled branches/tags.

Require:

```text
PR
Code Review
Security Checks
Ansible Lint
Tests
Approval
```

---

# 28. API Design

Design the automation interface so it can be invoked by:

```text
ServiceNow
GitHub Actions
AAP
Future Chatbot
Future AI Agent
Future API consumers
```

Example APIs:

```text
POST /server/build
POST /server/destroy
POST /server/validate
POST /server/post-build
GET  /server/{request_id}
GET  /server/{request_id}/status
```

Implement:

```text
Authentication
Authorization
Schema validation
Rate limiting
Idempotency
Correlation IDs
Audit logging
RBAC
```

---

# 29. Future AI/Chatbot Compatibility

The platform must eventually support:

```text
User
 |
 v
Chatbot / AI Agent
 |
 v
ServiceNow
 |
 v
Automation API
 |
 v
Ansible
```

The AI must NOT directly execute arbitrary Ansible commands.

AI should only generate a structured request:

```json
{
  "application": "PAYMENTS",
  "environment": "PROD",
  "server_role": "APPLICATION",
  "os": "WINDOWS",
  "count": 2
}
```

The policy/configuration engine remains the authoritative layer.

---

# 30. Deliverables

Generate the project incrementally.

Phase 1:

```text
Repository structure
ansible.cfg
requirements.yml
inventories
roles
playbooks
schemas
README
```

Phase 2:

```text
Configuration resolver
Request schema
Validation
Naming engine
Image resolver
```

Phase 3:

```text
Azure provisioning
AWS provisioning
GCP provisioning
```

Phase 4:

```text
Linux OS configuration
Windows OS configuration
```

Phase 5:

```text
Post-build automation
Domain join
Monitoring
Security
Backup
DNS
CMDB
```

Phase 6:

```text
GitHub Actions
```

Phase 7:

```text
AAP integration
```

Phase 8:

```text
ServiceNow integration
```

Phase 9:

```text
Security hardening
Testing
Observability
Audit
```

Phase 10:

```text
Documentation
Architecture diagrams
Runbooks
Operations guide
Developer guide
ServiceNow integration guide
```

---

# 31. Important Constraints

Do NOT:

* Create one giant playbook
* Hard-code cloud IDs
* Hard-code subnet IDs
* Hard-code image IDs
* Store passwords in Git
* Store cloud secrets in GitHub
* Pass credentials through ServiceNow
* Allow arbitrary Ansible command execution
* Duplicate automation logic between GitHub and AAP
* Couple business logic directly to Azure/AWS/GCP modules
* Make users provide technical infrastructure parameters unnecessarily
* Use `latest` for production dependencies
* Use shell/command when an idempotent Ansible module exists
* Build OS images as part of this project

---

# 32. Required First Output

Before creating implementation code, produce:

1. Enterprise architecture diagram
2. Logical architecture
3. Repository structure
4. Request lifecycle
5. ServiceNow → GitHub Actions flow
6. ServiceNow → AAP flow
7. Configuration resolution model
8. Azure architecture
9. AWS architecture
10. GCP architecture
11. Security architecture
12. Secret-management architecture
13. API contract
14. Ansible role dependency model
15. Execution Environment design
16. CI/CD pipeline
17. Failure/retry architecture
18. Idempotency strategy
19. Testing strategy
20. Implementation roadmap

Then wait for approval before generating the implementation.

The implementation must be production-oriented, modular, cloud-agnostic, secure, idempotent and extensible.

Start with the **architecture and repository design**, not with individual Ansible tasks.

