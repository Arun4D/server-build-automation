# Secret Management Architecture

Status: **Phase 1 — Proposed**

How secrets reach the platform, who holds them, how they are rotated, and — as the design goal
— how the platform arranges for almost none of them to exist.

Primary decision: [AD-15](../architecture/architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs).
Related: [security-architecture.md](security-architecture.md).

**No credential, token, password, key or connection string appears in this repository, in a run
contract, in an Ansible extra-var, in a GitHub Actions input or `env:`, in an AAP survey, in a
cloud tag, or in the run-state store.** Phase 1 creates none and this document specifies none.

---

## 1. The Design Goal: Fewer Secrets, Not Better-Held Secrets

Most secret-management work in an automation platform is spent on where to *put* a password.
The higher-leverage move is to arrange that there is no password to put.

```
  Best  ──▶  no secret exists
            OIDC / workload identity / managed identity.
            The cloud trusts the *claim*; there is no stored value to leak,
            rotate or accidentally commit.

  Good ──▶  a secret exists but is short-lived and job-scoped.
            A federated credential with a 60-minute TTL, issued at job start
            and destroyed at job end.

  OK   ──▶  a secret exists in an enterprise credential store, referenced
            by name only, never read by a job user, never logged.

  Bad  ──▶  a secret exists in git, in a CI variable, in a survey, in an
            extra-var, or in a workflow input. Logged, visible in job
            detail pages, rotatable only by editing the artifact.
```

The platform targets the first three tiers for everything it can, and tier 4 only for the
residuals: a domain join account, a CMDB OAuth client, an agent enrolment token, a DNS API
token. Those genuinely require a stored value, and each is handled in the credential store
with the controls in [§4.1 ](#41-credential-store-design).

---

## 2. Where Secrets Live

| Secret class | Holder | Mechanism | Lifetime | Rotated by |
|---|---|---|---|---|
| Cloud control plane (GHA) | — (none stored) | GitHub OIDC → cloud short-lived token | Per job, ≤1 h | N/A |
| Cloud control plane (AAP) | — (none stored) where the AAP instance has a role | OIDC / instance profile / managed identity | Per job or per instance | N/A |
| Run-state store access | — (none stored) where possible | Managed identity / workload identity | Per run | N/A |
| AAP job credentials (residuals) | AAP Credential store, external backend | Credential type + ID reference | Long | Replace the credential object; no code change |
| Domain join | AAP Credential store | `username` + `password`, `no_log` | Long | AD password rotation + credential update |
| CMDB write | AAP Credential store | OAuth2 client credentials | Long | ServiceNow secret rotation + credential update |
| DNS API | AAP Credential store | Scoped token | Long | Provider rotation |
| Agent enrolment (monitoring/backup/vuln) | AAP Credential store | Token or header | Medium | Provider rotation |
| GitHub → cloud federation | Cloud side (federated identity trust) | Trust policy with pinned `sub` | Long | Policy update |
| ServiceNow → platform auth | ServiceNow OAuth / AAP OAuth | Client credentials, scoped | Medium | Rotation + platform update |
| SCM credentials for AAP sync | AAP Credential store | Deploy key or scoped token | Long | Rotation |
| EE registry pull | AAP instance role / GitHub App | Registry identity | Long | Rotation |

**The rule that matters:** the *name* of a credential is configuration (committed, reviewable);
the *value* is not. A playbook says `sba-domainjoin`; the engine binds it.

```yaml
# roles/domain/windows_domain_join/defaults/main.yml  — committed, reviewable
sba_domain_join_credential: sba-domainjoin       # a NAME, resolved by the engine
sba_domain_join_user: "{{ sba_domain_join_account }}"   # an account name, not a secret
```

---

## 3. GitHub Actions

### 3.1 The position: no cloud secret exists in GitHub

```
  GitHub stores, for this repository:
      - OIDC trust configuration (claims, no value)
      - the GitHub App / deploy key used by AAP to sync the repository
      - the EE registry pull identity

  GitHub does NOT store:
      - an Azure client secret
      - an AWS access key
      - a GCP service-account key
      - a WinRM password
      - a domain join password
      - a ServiceNow client secret
```

### 3.2 OIDC pattern

```yaml
- name: Azure
  if: matrix.provider == 'azure'
  uses: azure/login@v2                    # pinned by SHA in the real workflow
  with:
    client-id:  ${{ vars.AZURE_CLIENT_ID }}      # public identifier, a variable not a secret
    tenant-id:  ${{ vars.AZURE_TENANT_ID }}     # public
    audience:   api://AzureADTokenExchange
    use-oidc:   true

- name: AWS
  if: matrix.provider == 'aws'
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::<acct>:role/svc-sba-github-nonprod
    aws-region: ${{ matrix.region }}
    role-session-name: sba-${{ inputs.request_id }}     # appears in CloudTrail

- name: GCP
  if: matrix.provider == 'gcp'
  uses: google-github-actions/auth@v2
  with:
    workload_identity_provider: ${{ vars.GCP_WIF_PROVIDER }}
    service_account: ${{ vars.GCP_SA_EMAIL }}
```

`client-id` and `tenant-id` are *variables*, not secrets, because they are public identifiers —
the thing that is secret is the **key** that signs the assertion, and that key never exists in
GitHub. Classifying a client id as a secret is a common and unhelpful reflex: it prevents
rotation, adds it to every developer's access list, and protects nothing.

`role-session-name` set to the request id means every AWS API call in CloudTrail carries the
ServiceNow request id. That is a free, high-value audit link.

### 3.3 What the workflow gets for other needs

| Need | How |
|---|---|
| `context.json` from the run-state store | The job's **cloud identity** — no key. The role has `sba-state` on `sba-runs/{env}/**` |
| WinRM/SSH to the target | The runner's instance identity plus a short-lived certificate, or an SSM/IMDS session for Azure. **No stored WinRM password in GitHub** |
| Domain join | Not performed from GitHub. If the environment requires it, the credential comes from the AAP credential store via a delegated service call, or the domain join stage is routed to AAP for that environment ([OQ-02](../open-questions.md#2-important--an-answer-is-needed-before-phase-4)) |
| CMDB write | Same as domain join — the callback is adapter-side; the CMDB write uses an AAP credential |

The last two rows are the pragmatic consequence of
[AD-15](../architecture/architectural-decisions.md#ad-15-no-secrets-in-extra_vars--workflow-inputs): GitHub Actions has no
credential store, so any stage needing a long-lived residual credential is either federated
(fine) or routed to AAP. Documenting that honestly is better than quietly putting a password in
a GitHub Secret and calling it a temporary measure.

### 3.4 Environment secrets inventory

| Environment | Environment secrets | Environment variables |
|---|:--:|---|
| `dev` | **0** | `SBA_ENV`, `SBA_STATE_PREFIX` |
| `nonprod` | **0** | `SBA_ENV`, `SBA_STATE_PREFIX` |
| `prod` | **0** | `SBA_ENV`, `SBA_STATE_PREFIX` |

Repository secrets: the EE registry read token and the AAP sync token only — both scoped to
this one repository, both readable only by the platform automation identity, neither usable by a
workflow step. A step-level `permissions` allow-list CI check enforces that no step can read
them.

---

## 4. Ansible Automation Platform

### 4.1 Credential store design

```
  AAP Credential store (external backend: HashiCorp Vault, or the enterprise
  secret manager, via a Credential Input Plugin — never the database)

  Credentials are referenced by NAME from job templates and from role defaults.
  A user with permission to LAUNCH a job can use a credential without ever
  being able to READ it. That property is the primary reason AAP is the
  production engine [AD-09](../architectural-decisions.md#ad-09-per-environment-engine-routing).
```

### 4.2 Credential register

Full register with usage rules: [servicenow-aap.md §7 ](../architecture/servicenow-aap.md#7-credentials). The
control properties that apply to all of them:

| Property | Requirement | Why |
|---|---|---|
| `ask_*_on_launch` | **Disabled** | If enabled, the launcher supplies the value — the store is bypassed. Commonly missed, and it silently defeats AAP's central credential property |
| Read access | Never granted to a job-launching role, ever | A user who can read credentials can exfiltrate them with a job |
| External backend | Yes, for anything not managed-identity-backed | Keeps secrets out of the AAP database, so an AAP compromise is not a credential compromise |
| Environment scoping | Separate stores (or at minimum separate names and instance groups) per environment | A dev user referencing `sba-cloud-azure-prod` by name must be impossible |
| Naming | `sba-<purpose>-<system>-<env>` | Makes an unrecognised name in a job template a review finding |
| Usage | Only in the roles that need it, with `no_log: true` | Limits both exposure and the blast radius of a role change |

### 4.3 `no_log` discipline

```yaml
# WRONG - the value appears in the job log
- name: Join the domain
  ansible.windows.win_domain_join:
    domain_user_name: "{{ sba_domain_join_user }}"
    domain_user_password: "{{ sba_domain_join_password }}"
    domain_name: "{{ sba_domain_name }}"

# RIGHT - the value is never rendered
- name: Join the domain
  ansible.windows.win_domain_join:
    domain_user_name: "{{ sba_domain_join_user }}"
    domain_user_password: "{{ sba_domain_join_credential | password }}"
    domain_name: "{{ sba_domain_name }}"
  no_log: true
```

`no_log: true` is asserted by a CI rule: any task that references a credential in a `password`,
`token`, `secret` or `key` field must be `no_log: true` or the build fails. This is a
mechanical check rather than a review convention, because "did you remember `no_log`" is exactly
the kind of thing that survives review until it does not.

`no_log` hides the task's result, which means `register` + `until` on such a task loses its
diagnostics. The pattern used instead is to register, assert on a **derived boolean**, and log
that:

```yaml
- name: Wait for WinRM after reboot
  ansible.windows.win_wait_for_connection:
    timeout: 900
  register: sba_winrm_wait
  until: sba_winrm_wait is succeeded
  retries: 30
  delay: 30
  no_log: true

- name: Record WinRM recovery outcome
  ansible.builtin.set_fact:
    sba_winrm_recovered: "{{ sba_winrm_wait is succeeded }}"
  # logged separately so the outcome is visible even though the task is not
```

### 4.4 AAP-specific leakage paths to close

| Path | Control |
|---|---|
| `extra_vars` visible in the job detail page and audit log | Pass only `run_context_id` ([servicenow-aap.md §3.1 ](../architecture/servicenow-aap.md#31-why-only-run_context_id-is-passed)) |
| `job_tags` visible in the UI | Business identifiers only; no resolved technical values |
| Surveys | Not used for technical parameters ([C-16](../architecture/architectural-decisions.md#2-requirement-conflict-register)); a survey field can only narrow, never specify |
| `job_template.extra_vars` default | Kept to `sba_git_sha` and `sba_correlation_id` placeholders — never a value |
| Job log file on disk | `log_path` disabled; AAP's own log store, with retention, is the only copy |
| The `svc-sba-servicenow` token | Launch-only on a single template; it cannot read credentials or create templates |
| Events | AAP's event stream is exported to the SIEM, so credential *use* is recorded even if the value never is |

---

## 5. Cloud-native identity (the preferred tier)

| Cloud | Preferred | Fallback | Avoid |
|---|---|---|---|
| **Azure** | Managed identity on the AAP instance or runner VMSS; OIDC from GHA | AAD app registration with a federated credential (no secret) | Client secret |
| **AWS** | IAM role for the instance profile; GitHub OIDC federation | AAD/instance role with a short session | Long-lived access key |
| **GCP** | Workload identity; attached service account on the instance | Short-lived service-account token via the metadata server | Downloaded JSON key |

### 5.1 Two cloud identities, not one

Per [security-architecture.md §3.1 ](security-architecture.md#31-the-provisionread-split-is-the-important-one):

```
  sba-{cloud}-{env}-read       pre-flight.  describe / list / usages / read.
                               NO create. NO delete. NO write of any kind.

  sba-{cloud}-{env}-provision  stages 1-3.  create / read / delete on the
                               specific resource types in the catalogue,
                               scoped to the catalogue's resource groups /
                               projects / VPCs. NO iam / rbac / network write.
```

This is enforced by a test that attempts a write with the read identity and asserts denial, in
every environment. A permission that is merely *absent from the design document* is not a
control.

### 5.2 Federation policy requirements

Every cloud trust policy must pin **all** of:

| Pin | Attack prevented |
|---|---|
| Exact account / subscription / project | Any other workload, including a dependency's fork, assuming your identity |
| Exact environment (`dev`/`nonprod`/`prod`) | A dev workflow assuming the prod identity |
| Ref allow-list (branch/tag) | A compromised branch or an arbitrary ref — including a PR branch — assuming a production identity |
| Exact audience | Token replay across services |
| Optional: signed claims, and an org/user condition | A token minted by a workflow in a different org |

A policy that pins only the account is functionally equivalent to no federation at all, and this
is the single most common misconfiguration in OIDC setups. It is asserted in the OIDC negative
test suite ([security-architecture.md §10 ](security-architecture.md#10-security-testing)).

---

## 6. Ansible Vault Policy

§15 permits Ansible Vault "only where appropriate". This project defines "appropriate" as
**nothing committed to this repository.**

| Use | Permitted? | Where the value lives |
|---|---|---|
| Long-lived secret in the repository | **No** | Credential store / cloud identity |
| Secret in a `group_vars` file | **No** | Credential store / cloud identity |
| Connection password for a control-plane host | **No** | AAP Credential store |
| Ephemeral local developer scratch, git-ignored | Yes | `*.vault` locally only; `vault_password_file` is git-ignored |
| A value needed by a test fixture | **No** | A canary test value, never a real credential |
| Encrypting non-secret-but-sensitive config (e.g. internal hostnames) | Not recommended | A non-secret config file with review; encryption without a secret boundary buys nothing |

Rationale, briefly: a Vault-encrypted file in git is still a file whose plaintext is
recoverable by anyone with the password, and the password then has to live somewhere — a CI
variable, a runner secret, a developer's laptop. That converts "a secret in git" into "a
secret in git plus a secret in CI plus a secret on laptops", which is strictly worse than the
alternative of having no secret in git at all. Vault is a good tool for encrypting data at rest
in transit to a consumer; it is a poor substitute for not committing the data.

`.gitignore` excludes `*.vault`, `vault_password_file`, `.vault_pass`, and
`tests/fixtures/secrets/`, and CI asserts none of them are tracked.

---

## 7. Rotation

| Secret | Rotation period | Trigger | Procedure | Code change? |
|---|---|---|---|---|
| Cloud federated trust policy | 90 d | Policy change | Update the claim conditions | No |
| AAP ↔ cloud identity | 90 d | Instance replacement | Replace the identity binding | No |
| `sba-domainjoin` | 90 d, and on any suspected exposure | AD password change | Rotate in AD, update the credential object | **No** — roles reference the name |
| `sba-servicenow-cmdb` | 90 d | ServiceNow secret rotation | Rotate, update the credential object | No |
| DNS API token | 90 d | Provider rotation | Rotate, update the credential | No |
| Agent enrolment tokens | Per provider (often 180 d) | Provider policy | Rotate, update the credential | No |
| `svc-sba-servicenow` (SN → platform) | 90 d, and on any ServiceNow admin change | Token rotation | Rotate the SN OAuth secret, update the AAP integration | No |
| SCM deploy key | 180 d | Repo/org policy | Rotate, update the AAP credential | No |
| EE registry token | 90 d | Policy | Rotate, update the credential | No |

**Every rotation is a credential-object update. None requires a code change, a playbook edit, or
a redeploy.** That is a direct design consequence of referencing credentials by name, and it is
the property that makes a 90-day rotation cycle operationally feasible across three clouds and
two engines. A design that embedded credential *names* in playbooks would make rotation a
release; a design that put values in playbooks would make it impossible.

### 7.1 Emergency rotation procedure

For a suspected exposure:

```
  1. Revoke at the source       (AD password change, OAuth secret rotation,
                                 cloud trust-policy removal)
  2. Replace the credential     (new value in the credential store; same name)
  3. Verify                     (a canary run: confirm success and no
                                 use of the old value in the logs)
  4. Investigate                (AAP event stream for credential use;
                                 cloud OIDC logs; AD object-creation events)
  5. Do NOT rotate the NAME     (a name change requires a code change, which
                                 is exactly what the design avoids)
```

Step 5 is the payoff of name-based referencing: emergency rotation is a five-minute operation
with no release, no deployment, and no risk of a code/deployment mismatch leaving a stale
credential in use.

---

## 8. In-Guest Secrets

Secrets that must exist **on** the build target. Each is a genuinely hard problem and each gets
a defined, documented treatment rather than a "handled securely" hand-wave.

| Secret | Problem | Treatment |
|---|---|---|
| Local administrator password | Must exist on the host | Generated on the target from a cryptographic source, never passed in. Stored in the LSA, not in Ansible. Password reset via the directory for domain-joined hosts. **Never in a playbook, a variable, or the run-state store** |
| Service account password | Must be usable by an application | Set by the application onboarding stage, not the build stage. Passed once via WinRM/SSH over TLS, `no_log: true`, and the run-state store records only *that* it was set, never the value |
| WinRM/SSH admin credential | Needed to manage the host | Prefer certificate-based or directory-integrated auth, so no stored credential exists. If a credential is required, it is a per-host credential in the store, created by the build and rotated on a schedule — and a per-host credential per server is a real cost, which is why certificate/directory auth is preferred |
| Agent enrolment tokens | Must reach the agent | Fetched by the agent from the management platform with a one-time token; the token is single-use and expires in minutes. The playbook passes the token, not a long-lived API key |
| Join account | Must be present during the join | Used once, then the account is not cached on the host. The host joins with a machine account; the join credential is not persisted |
| Application secrets | Out of scope | The build stage does not set them. Application onboarding (Stage 8) owns them, and they come from a secret manager at runtime, not at build time |

The recurring principle: **a build should leave the host with as few long-lived secrets as
possible, and ideally with none that the platform had to transport.** Machine accounts, managed
identities (Azure IMDS, GCP metadata, AWS instance profiles) and one-time enrolment tokens
achieve that; a password-based local admin is the accepted residual, and it is generated on the
target rather than transported to it.

### 8.1 The local admin password, specifically

```yaml
# Generated on the target. Never a variable, never transported, never stored by the platform.
- name: Set the local administrator password from a target-local random source
  ansible.builtin.user:
    name: "{{ sba_local_admin_pattern }}"
    password: "{{ lookup('ansible.builtin.password', '/dev/null', length=24, chars=['ascii_letters','digits']) }}"
    state: present
    update_password: always
  no_log: true
```

The value is generated on the managed node and is not recoverable by the platform afterwards.
For domain-joined hosts the account is subsequently managed by the directory, so the platform
never needs to reset it. If an operator genuinely needs a break-glass path, it is a directory
managed account, not a password the platform holds.

---

## 9. Detection

Detection is what turns a policy into a control. Every mechanism below is paired with an
**alert**, because a redaction or detection rule that silently matches is indistinguishable from
one that is not running.

| Detection | Mechanism | Alert |
|---|---|---|
| Secret committed | `gitleaks` pre-commit hook + CI on every push | PR/branch blocked; security notified on `main` |
| Secret in the git history | `gitleaks` over full history in CI | Build fails; rotation initiated |
| Secret in a workflow input or `env` | Custom CI check against the input allow-list | Build fails |
| Secret in an extra-var | Custom lint rule + a grep gate on `password`/`token`/`secret` in `extra_vars` | Build fails |
| Secret in a cloud tag | TagMapper emits no key matching the sensitive pattern; asserted in the resolver test suite | Test failure |
| Secret in the run-state store | Canary test scans every object of a test run for the canary value | Test failure |
| Secret in a log or artifact | Canary test + SIEM ingest-side redaction with an alert on match | SIEM alert |
| `no_log` removed | CI lint rule requiring `no_log` on credential-consuming tasks | Build fails |
| Unexpected credential use | AAP event stream → SIEM; a credential used by a template that has never used it | SIEM alert |
| Long-lived or over-privileged identity | Scheduled access review of cloud and AAP identities | Review ticket |
| Vault file in the repo | `.gitignore` + CI assertion that no `*.vault` is tracked | Build fails |
| Cloud API call from an unexpected principal | Cloud activity log correlation against the known identity set | SIEM alert |

The **canary leak test** is the one that verifies the whole path rather than a single mechanism:
a distinguishing value is placed in a test credential store, a full build runs, and every sink
is searched. It is run per engine, because the two engines have genuinely different log and
detail-page behaviour, and a control verified on one is not verified on the other.

---

## 10. Inventory of Every Place a Secret Could Leak

Exhaustive, because the value of this list is in the rows that are *not* obvious.

| # | Location | Mitigation | Verified by |
|---|---|---|---|
| 1 | Git source | Zero secrets; `gitleaks` blocking; history scanned | CI |
| 2 | Git commit message | Conventional format; no values; pre-commit check | CI |
| 3 | PR description / issue | No credential is ever quoted from a log | Process |
| 4 | `ansible.cfg` | No `vault_password_file`; no default vault id | CI |
| 5 | `requirements.txt` | Hash-pinned, no private index credentials | CI |
| 6 | Run contract | No field can hold a secret (closed schema) | Contract tests |
| 7 | `extra_vars` | Only `run_context_id` crosses into AAP | Adapter test |
| 8 | GitHub workflow `inputs` | Allow-list; custom check | CI |
| 9 | GitHub workflow `env` | No secret; `vars` for public identifiers | CI |
| 10 | GitHub repository/environment secrets | Only the EE registry and AAP sync tokens; no step may read them | Permission check |
| 11 | AAP `extra_vars` | `run_context_id` only | Template inventory test |
| 12 | AAP survey | No technical parameters; a survey can only narrow | Template inventory test |
| 13 | AAP job tags | Business identifiers only | Template inventory test |
| 14 | AAP job detail page / audit log | No values passed; `no_log` on consumers | Canary test |
| 15 | AAP job log file on disk | `log_path` disabled | Config review |
| 16 | Ansible task output | `no_log: true`, lint-enforced | CI + canary |
| 17 | Ansible registered results | Only derived booleans registered from `no_log` tasks | Lint rule |
| 18 | Ansible callback output | `stdout_callback` restricted; `log_path` off | Config review |
| 19 | Shell tracing | No `set -x`; lint-enforced | `ansible-lint` |
| 20 | Failure messages | Closed templates; no raw exception to the requester | Resolver test |
| 21 | Cloud tags / GCP annotations | TagMapper emits no sensitive key; value patterns checked | Resolver test |
| 22 | Run-state store | Never written by any role; asserted in the state client | Canary test |
| 23 | `context.json` | Resolver emits no credential by construction | Golden-file test |
| 24 | Cloud resource names | Resolver output only; no free-text from a requester | Resolver test |
| 25 | ServiceNow RITM fields | Summary only; no technical values; no secrets | Callback test |
| 26 | ServiceNow work notes | Summary + `resolved_config_hash` | Callback test |
| 27 | ServiceNow CMDB | Server facts only; no credential field is ever written | CMDB role test |
| 28 | Callback payload | Summary schema; signed; no secrets | Callback test |
| 29 | AAP event stream | Records *which* credential, never its value | Config review |
| 30 | Cloud activity logs | Contain no credential (OIDC), or a redacted one | Cloud review |
| 31 | AD event log | Computer-object events; no password | AD review |
| 32 | SIEM | Ingest-side redaction + alert on match | SIEM test |
| 33 | Container/EE image layers | No secret baked in; image scanned for secrets | `trivy`/`gitleaks` on the image |
| 34 | Runner disk after a job | Ephemeral runner, recycled; nothing persists | Runner hygiene test |
| 35 | Molecule / test fixtures | Canary values only; `tests/fixtures/secrets/` git-ignored | CI |
| 36 | Documentation and diagrams | Placeholders only; no real identifiers | Review |
| 37 | Local developer machine | `*.vault` git-ignored; no production credential on a workstation | Process |
| 38 | Backup of the run-state store | Encrypted; access-logged; classified | Platform review |

Thirty-eight rows, and rows 17, 22, 24, 28, 33 and 34 are the ones that are routinely missed.
The most common real-world leak in Ansible automation is not a committed password — it is a
credential in an extra-var (row 7/11), a value in a registered result (row 17), or a secret
baked into a container layer (row 33).

---

## 11. Next

- Identity model, RBAC and trust boundaries: [security-architecture.md](security-architecture.md)
- AAP credential register: [servicenow-aap.md §7 ](../architecture/servicenow-aap.md#7-credentials)
- OIDC policy detail: [security-architecture.md §3.2 ](security-architecture.md#32-cloud-permission-shape-example-azure)
- Canary leak test design: [../testing/testing-strategy.md](../testing/testing-strategy.md)
