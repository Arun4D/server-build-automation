# Server Build Automation Platform

Enterprise, multi-cloud, ServiceNow-integrated server provisioning automation for **Azure, AWS and
GCP**.

> **Status: Phase 1 — Documentation and structure. No implementation code exists yet.**
> All 22 architectural decisions are `PROPOSED` and awaiting approval. See
> [docs/roadmap.md](docs/roadmap.md).

---

## What This Is

A requester raises a standard ServiceNow request. The platform resolves it against a reviewed
catalogue, validates it against policy, and provisions a correctly named, correctly tagged,
correctly monitored, correctly registered server on the right cloud in the right region — with a
DNS record, a CMDB record, and domain-joined, CIS-hardened, agent-enrolled guests — and reports
the outcome back to the request.

**It is a build platform, not a portal.** ServiceNow is the interface. There is no second UI.

```
  ServiceNow RITM
        │  OIDC
        ▼
   Adapter ──┬──▶ GitHub Actions  (dev, nonprod)
             └──▶ AAP             (prod, with approval)
                        │
                        ▼
              Resolver ──▶ Policy gate
                        │
                        ▼
     Azure / AWS / GCP ──▶ OS config ──▶ Domain join
                        │
                        ▼
     DNS record ◀── Agents ◀── Monitoring ◀── Backup
                        │
                        ▼
                  ServiceNow CMDB
                        │
                        ▼
              Callback ──▶ RITM state
```

---

## Start Here

| You want | Read |
|---|---|
| The decisions to approve | [docs/architecture/architectural-decisions.md](docs/architecture/architectural-decisions.md) |
| An overview | [docs/architecture/enterprise-architecture.md](docs/architecture/enterprise-architecture.md) |
| The full documentation index | [docs/README.md](docs/README.md) |
| What Phase 1 delivered | [docs/roadmap.md](docs/roadmap.md) |
| What still needs deciding | [docs/open-questions.md](docs/open-questions.md) |
| What the design assumes | [docs/assumptions.md](docs/assumptions.md) |
| Terms | [docs/glossary.md](docs/glossary.md) |

---

## The Eleven Stages

| # | Stage | Gate |
|---:|---|---|
| 1 | `validate` | Nothing created. Contract and configuration must resolve |
| 2 | `bootstrap` | Approval recorded. Transient admin credentials issued |
| 3 | `provision` | Infrastructure created, tagged with `sba_instance_id` |
| 4 | `os_config` | Packages, hardening, local accounts |
| 5 | `validate_os` | The configuration is what it was supposed to be |
| 6 | `domain_join` | The AD computer object exists |
| 7 | `install_agents` | Agents installed |
| 8 | `enroll_agents` | Agents reporting |
| 9 | `dns` | A and PTR records, for healthy hosts only |
| 10 | `cmdb` | One CI record, per healthy host |
| 11 | `post_build` | A single stage re-runnable in isolation |

Gates 1-3 create nothing on failure. After gate 3, failures **retain** infrastructure for
forward-fix rather than destroying it.

---

## The Design in One Page

| Concern | Decision |
|---|---|
| **One entry point** | A single stage-parameterised `server_build.yml`. Stage re-entry through durable state, not a second playbook ([AD-01](docs/architecture/architectural-decisions.md)) |
| **One contract** | Engine-neutral, provider-neutral, business-only, versioned ([AD-02](docs/architecture/architectural-decisions.md)) |
| **One key** | `sba_instance_id`, a UUID assigned by ServiceNow before anything exists, and applied as a tag in the same call that creates the resource ([AD-05](docs/architecture/architectural-decisions.md)) |
| **One config model** | A pure, deterministic resolver produces a single effective configuration per run ([AD-22](docs/architecture/architectural-decisions.md)) |
| **One state store** | An object store, one prefix per request, CAS for locking ([AD-04](docs/architecture/architectural-decisions.md)) |
| **No dynamic dispatch** | Provider roles are selected by a static enum. No user-controlled role name, ever ([AD-08](docs/architecture/architectural-decisions.md)) |
| **No secrets anywhere** | OIDC federated identities. No secret in git, a contract, extra-vars, a survey, a workflow input, or run state ([AD-15](docs/architecture/architectural-decisions.md)) |
| **Forward-fix, not destroy** | A failed build keeps its infrastructure ([AD-16](docs/architecture/architectural-decisions.md)) |
| **Nothing silently succeeds** | Every stage has an assertion, and a `PARTIAL` batch is a first-class outcome |

---

## Repository Layout

```
.github/workflows/      Runtime workflows (canonical) + the platform's own CI/CD
docs/                   Architecture, API, security, testing, runbooks
schemas/                JSON Schema for every wire document
playbooks/              server_build.yml and the stage wrappers
roles/                  platform/ cloud/ image/ os/ domain/ dns/ cmdb/ security/ monitoring/ backup/
configuration/          Split by kind: clouds/ regions/ applications/ server_roles/ os/ images/
                        environments/ policies/ routing/ tags/ naming/
automation/             github/ aap/ servicenow/
execution-environment/  Dockerfile and pinned requirements
inventories/            dev/ nonprod/ prod/ — control-plane hosts only
scripts/                resolve_configuration.py, sba_state, lib/sba_resolver/
tests/                  unit/ integration/ e2e/ molecule/ fixtures/ security/
mock/                   Mock ServiceNow and state store for local runs
```

Full detail, with the rationale for each choice:
[docs/architecture/repository-structure.md](docs/architecture/repository-structure.md).

---

## The Decisions

Twenty-two, each with its rationale, its alternatives, and its consequences:
[docs/architecture/architectural-decisions.md](docs/architecture/architectural-decisions.md).

The five that shape everything else:

| | Decision | Why |
|---|---|---|
| `AD-01` | One entry playbook, stage re-entry via durable state | A second entry playbook for post-build work is a second place for the stage order to be wrong |
| `AD-05` | `sba_instance_id` is a caller-generated UUID, tagged at create | It is the only design where create-or-adopt, IAM scoping, and cross-system joins all work from one value |
| `AD-08` | Closed provider enum, static dispatch | A user-controlled role name is arbitrary code execution with extra steps |
| `AD-15` | No secrets in extra-vars, contracts, inputs, or state | Extra-vars are logged, and state is retained. Anything placed there is disclosed |
| `AD-16` | Retain on failure, forward-fix | Auto-destroy orphans domain objects, DNS records and CMDB records, and destroys the evidence |

---

## What Is Not In Scope

A portal or UI. A gateway state machine. Kubernetes or database provisioning. Post-build
arbitrary orchestration. A provider plugin API. Automatic rightsizing. Automatic OS upgrades.

The reasoning for each exclusion is in
[docs/roadmap.md §11 ](docs/roadmap.md#11-explicitly-out-of-scope).

---

## Development

Not yet applicable — Phase 2 begins after approval. The intended commands are documented in
[docs/architecture/repository-structure.md §15 ](docs/architecture/repository-structure.md#15-makefile).

---

## Contributing

Not yet applicable. `CODEOWNERS`, pull request templates, and the branch model are specified in
[docs/architecture/cicd-pipeline.md §3 ](docs/architecture/cicd-pipeline.md#3-branch-and-promotion-model)
and will be created in Phase 2.

---

## Documentation

Everything is in [docs/](docs). Start with [docs/README.md](docs/README.md), which has a reading
path for each audience.

---

## Phase 1 Contents

| Area | Documents |
|---|---|
| Architecture | 17 documents covering decisions, views, lifecycle, both engines, three clouds, failure/retry, idempotency, CI/CD, structure |
| API | The contract, run context, run result, stage result, callback, error registry |
| Security | Security architecture, secret management |
| Testing | L1-L8 test layers, the pure-core rule, chaos, parity, canary, coverage |
| Project | Roadmap, assumptions, open questions, glossary, index |

**No implementation code, no credentials, no cloud resources, and no API calls** were created in
Phase 1. The repository contains documentation and an empty directory skeleton.
