# Assumptions

Status: **Phase 1 — Proposed**

Every assumption the design depends on, why it was made, what breaks if it is wrong, and how to
find out cheaply.

An assumption that is wrong is not a failure of the design; a wrong assumption that was never
written down is. This document exists so that the assumptions can be challenged during review
rather than discovered during Phase 4.

---

## 1. Environment and Estate

| # | Assumption | Basis | If wrong | How to find out |
|---|---|---|---|---|
| A-01 | Three clouds are in scope: Azure, AWS, GCP | The brief | Fewer: remove a provider from the catalogue. More: repeat the [provider checklist](architecture/provider-abstraction.md#9-adding-a-provider), and expect a major version per addition | A stakeholder question |
| A-02 | Azure is the primary cloud | The brief named it first | Phase 4 picks a different provider. The phase is provider-agnostic; only the sandbox differs | A stakeholder question |
| A-03 | Each environment maps to one cloud region | The brief | A region-per-environment assumption becomes a per-application region choice, which the model already supports | Phase 4 |
| A-04 | The estate is corporate on-premises AD, not Entra ID | The examples use `corp.example.com` | **Substantial rework.** Managed identity joins change the domain-join role, the `validate_os` assertions, and the retry profile. The design would need a `domain_provider` dimension | Confirm with the directory team |
| A-05 | Workloads are IaaS VMs, not containers | The brief | Phase 4 becomes a different platform. Kubernetes is [out of scope](roadmap.md#11-explicitly-out-of-scope) | A stakeholder question |
| A-06 | Windows is the dominant OS, Linux is also required | The examples | Both roles are symmetric; removing one is easy | Phase 5 |
| A-07 | Gold images already exist or will be produced by a separate pipeline | The catalogue references pinned gallery images | Phase 4 needs an image pipeline first. This is a real schedule risk, not a technical one | Ask the image pipeline team |
| A-08 | There is a CMDB with a CI class for servers | The brief | `servicenow_cmdb` is replaced with another CMDB. The role boundary is the same | Ask the CMDB team |
| A-09 | DNS is a delegated zone the platform can write | The brief | A DNS change process replaces `dns_registration`, adding an approval step | Ask the network team |
| A-10 | There is a monitoring platform, a security agent platform, a vulnerability scanner, and a backup platform with APIs or agents | The examples | Each post-build role becomes an install-only role. The architecture is unchanged | Ask the ops team |

---

## 2. ServiceNow and AAP

| # | Assumption | Basis | If wrong | How to find out |
|---|---|---|---|---|
| A-11 | A ServiceNow Business Rule can call an external endpoint | Common capability | A Flow Designer Flow or an IntegrationHub spoke instead. The payload contract is unchanged | Check the ServiceNow version |
| A-12 | The "Standard Request Catalog" item is the request mechanism | The brief | Any intake form works. The contract is the same | A stakeholder question |
| A-13 | A production build requires a change record | Enterprise convention | A stricter or looser approval model changes [AD-17](architecture/architectural-decisions.md#ad-17-approval-authority-stays-in-servicenow) | Ask the change manager |
| A-14 | A self-hosted GitHub Actions runner is acceptable for nonprod and prod | It is needed for network reachability | A larger runner estate, or none, and the network design changes. **This is a significant dependency** | Ask the network team |
| A-15 | AAP is available; if not, AWX is acceptable | The brief | AWX has no approval workflow, so [AD-17](architecture/architectural-decisions.md#ad-17-approval-authority-stays-in-servicenow) enforcement moves entirely to ServiceNow plus a manual AAP launch | Check whether AAP is licensed |
| A-16 | AAP supports OIDC / external authentication | Required for `AD-15` | Client secrets must be used, which weakens the secret model. **A real degradation** | Check the AAP version |
| A-17 | GitHub Actions OIDC is available on the plan | Required for no long-lived cloud secrets | A PAT or client secret in a GitHub secret, which is a weaker but workable model | Check the plan |
| A-18 | A custom role can be created in ServiceNow | The brief | Approval would be enforced by a group membership check instead. Weaker, and a documented gap | Ask the ServiceNow admin |
| A-19 | The callback can update the RITM and the CI case from the platform | The brief | A MID Server relays the callback. A supported pattern, more moving parts | Ask the CMDB team |
| A-20 | Environment is derivable from the ServiceNow catalogue | The brief | An explicit environment field is added to the contract. Small change, and arguably more robust | A stakeholder question |

---

## 3. Networking

| # | Assumption | Basis | If wrong | How to find out |
|---|---|---|---|---|
| A-21 | DNS is authoritative in the delegated zone, with TTLs of 300-600 s | Enterprise practice | DNS propagation affects the retry budget. A 3600 s TTL would make `dns` the slowest stage | Query the zone |
| A-22 | The runner or AAP can reach the target subnets | A design requirement | Nothing works. A proxy, a bastion, or a runner per network zone is required | Test early; this is the single biggest schedule risk |
| A-23 | Private connectivity to each cloud is available (Private Link, transit, peering) | Enterprise practice | A NAT or VPN route instead. Performance and egress-control implications | Ask the network team |
| A-24 | Subnets are pre-created and IP capacity is managed outside the platform | [AD-18](architecture/architectural-decisions.md#ad-18-inventories-hold-control-plane-hosts-only) | The platform creates subnets, which is a much larger scope and a much larger blast radius | A stakeholder question |
| A-25 | No public IPs on production servers | Most security baselines | Public IPs become a catalogue option, with the egress implications | Ask the security team |
| A-26 | Private DNS resolution works from the target subnets for the CMDB and agents | Practical requirement | Agents use a proxy instead. Configuration change, not architectural | Test in Phase 4 |
| A-27 | DNS updates require no separate change approval | The brief | A DNS approval step is added to the flow | Ask the change manager |

---

## 4. Security and Compliance

| # | Assumption | Basis | If wrong | How to find out |
|---|---|---|---|---|
| A-28 | OIDC federated identities are acceptable to the cloud security teams | Modern practice | Workload identity federation (AWS) or a managed identity with a stored secret. A weaker model | Ask the security team **early** |
| A-29 | Cloud KMS / Key Vault / KMS key rotation can be performed by the platform identity | The brief | Rotation becomes a manual step, and the platform detects drift rather than fixing it | Ask the security team |
| A-30 | Disk encryption with a customer-managed key is required for regulated workloads | The examples | Encryption is optional. The capability is already modelled per catalogue entry | Ask the compliance team |
| A-31 | Trusted Launch / Shielded VM / IMDSv2 hardening is required | Security baseline | Drop from the catalogue metadata | Ask the security team |
| A-32 | Tag-based IAM conditions are acceptable for per-run least privilege | The design | Scope falls back to name-based IAM, which is weaker. See the GCP caveat in [gcp.md §8 ](architecture/cloud/gcp.md#8-per-run-least-privilege) | Test in Phase 4 |
| A-33 | The secret store supports short-lived dynamic credentials | Modern stores | Static credentials in the store, which is the model `AD-15` is designed to avoid | Check the store |
| A-34 | The organisation has a PKI and can issue certificates for agents and WinRM | Practical requirement | Self-signed certificates, with a documented trust gap | Ask the security team |
| A-35 | Audit logs are retained long enough to satisfy the audit requirement | Unknown | Retention architecture, outside this platform's scope | Ask the compliance team |
| A-36 | Compliance frameworks require an external attestation of the automation, not only of the servers | Unknown | The CIS roles are the platform's evidence instead | Ask the compliance team |

---

## 5. Data Model and Naming

| # | Assumption | Basis | If wrong | How to find out |
|---|---|---|---|---|
| A-37 | Each application has a stable code of 2-8 lowercase characters | The naming design | A code-generation step is added. The `patterns.yml` rules change | A stakeholder question |
| A-38 | A numeric server index per scope is the correct disambiguator | The naming design | A name derived from a CMDB field. The counter becomes a lookup | A stakeholder question |
| A-39 | `short_name` is a real requirement, not cosmetic | Windows/NetBIOS 15 characters | Long names become possible. The whole naming split simplifies | Confirm with the directory team |
| A-40 | Server names need to be globally unique within the DNS scope | Practical | Scope can be relaxed, allowing shorter names | A stakeholder question |
| A-41 | The canonical tag set is sufficient for cost allocation and inventory | The catalogue | More fields are added. They go into `tags/canonical_keys.yml` | Ask the FinOps team |
| A-42 | Cost centre and data classification come from the application record | The brief | They come from the requester, which makes them requester-controlled and therefore less trustworthy | Ask the FinOps team |
| A-43 | Requesters are not technical | The brief | The contract can be simplified, and a more expressive one may be needed instead | Observe actual requests in Phase 4 |

---

## 6. Process and People

| # | Assumption | Basis | If wrong | How to find out |
|---|---|---|---|---|
| A-44 | A platform team owns this codebase and the operational runbooks | Implicit | The operational burden is unowned, and the platform degrades | Confirm with management |
| A-45 | The ServiceNow customisation is under the platform team's control | Implicit | The integration is contract-bound and cannot evolve with the platform | Ask the ServiceNow team |
| A-46 | The legacy process is documented well enough to be replaced | The brief | Decommissioning needs more change management than technology | Ask the current process owners |
| A-47 | A 30-day pilot with one real application is acceptable | Phase 9 | A shorter or longer pilot. The exit criteria are unchanged | A stakeholder question |
| A-48 | Build duration of 20-60 minutes is acceptable to requesters | The examples | Expectation management, or a faster path. The stage budget is configurable | Ask requesters |

---

## 7. The Assumptions Most Likely to Be Wrong

Ranked by how much rework each would cause, because the point of this section is triage.

| Rank | Assumption | Rework if wrong | Early warning |
|---|---|---|---|
| 1 | **A-22** — the runner can reach the target subnets | **Severe.** A runner per network zone, or a proxy, changes the deployment architecture and the EE model | Any Phase 4 spike |
| 2 | **A-04** — corporate AD rather than Entra ID | **Severe.** Reworks the domain-join role, `validate_os`, and the retry profile for the most common failure mode | One question to the directory team |
| 3 | **A-16 / A-17** — OIDC on AAP and GitHub | **Moderate.** Falls back to stored client secrets, weakening the secret model throughout | A version check |
| 4 | **A-24** — subnets are pre-created | **Moderate.** Subnet creation is a large scope increase with a large blast radius | A stakeholder question |
| 5 | **A-14** — a self-hosted runner is acceptable | **Moderate.** Changes the deployment architecture | A network/security question |
| 6 | **A-07** — gold images exist or will exist | **Moderate.** A schedule dependency that cannot be compressed by writing more code | Ask the image pipeline team |
| 7 | **A-28** — federated identities are acceptable | **Moderate.** Degrades the whole secret model | A security review |
| 8 | **A-33** — the secret store supports dynamic credentials | **Moderate.** Static credentials become necessary | Check the store |
| 9 | **A-15** — AAP rather than AWX | **Low-moderate.** Approval enforcement moves to ServiceNews entirely | A licensing question |
| 10 | **A-24 / A-25** — no public IPs | **Low.** A catalogue option | A security baseline review |

**A-22 and A-04 are the two worth a stakeholder conversation before Phase 2 begins**, because
both change the architecture rather than the implementation, and both can be resolved with one
question each.

---

## 8. What Was Deliberately Not Assumed

| Not assumed | Why |
|---|---|
| A specific vendor for the secret store | The design uses an interface. Naming a vendor would constrain the choice for no benefit |
| A specific CI/CD vendor | GitHub Actions is the stated path; CI is a GitHub concern either way |
| A specific CMDB schema | The role boundary is the same whatever the CI class is called |
| A specific image format | The catalogue references provider-native images |
| That the legacy process is bad | It probably works. The case for the platform is consistency and auditability, not the absence of an alternative |
| That three providers are needed immediately | Phase 4 is one provider. If the business only needs one, phases 7's effort is better spent elsewhere |
| A target throughput | Not stated, and not needed for the design. It affects the concurrency semaphore's value, which is a tunable |

The last row is worth a moment. Several designs fail by optimising for a requirement nobody
stated. Not knowing the expected number of builds per day means the semaphore, the runner pool
and the batch size are all left as tunables, which is the honest position: a number invented here
would be a number nobody checked.

---

## 9. Next

- [open-questions.md](open-questions.md) — the decisions still needed
- [roadmap.md](roadmap.md) — the phases these assumptions gate
