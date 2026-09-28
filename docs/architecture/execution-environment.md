# Execution Environment Design

Status: **Phase 1 — Proposed**

The Ansible Execution Environment, the self-hosted runner model, version consistency between
the repository and the image, and the promotion path from a commit to a production toolchain.

Related: [cicd-pipeline.md](cicd-pipeline.md), [security-architecture.md §8 ](../security/security-architecture.md#8-network-and-host-security).

---

## 1. What the EE Is (and Is Not)

**It is** the controller-side toolchain: `ansible-core`, the collections, the Python and OS
dependencies, and the clients needed to talk to clouds and to managed hosts. It runs on the
runner/controller and orchestrates.

**It is not** a guest image. The build target's OS configuration happens *over* WinRM/SSH from
the EE. The target's own software comes from the approved image
([AD-07](architectural-decisions.md#ad-07-image-catalogue-with-pinning-and-expiry)) and from
internal package sources — never from the EE.

This distinction is the most common source of confusion in Ansible Execution Environment
projects, and getting it wrong leads to "why is `pywinrm` not on the Windows host" designs that
cannot work.

| Layer | Where it runs | What it provides |
|---|---|---|
| EE (controller) | Runner / AAP instance | `ansible-core`, collections, `pywinrm`, `boto3`, `azure`, `google-cloud-*`, `passlib`, `requests` |
| Runner | Self-hosted host | The container/EE runtime, the job identity, the network path to targets |
| Target | Build target | The OS, the approved image's software, internal package sources, the domain-joined identity |

The EE needs WinRM **and** SSH client libraries, because a single EE serves both OS families.
A separate Windows EE would be wrong — the controller-side requirements are the same.

---

## 2. Design

```
  execution-environment/
    execution-environment.yml     EE definition: base image, galaxy, python, OS deps,
                                  build args, build context, tags
    requirements.yml              Galaxy collections (pinned) — the single source of truth
    requirements.txt              Python packages (pinned, hashed)
    bindep.txt                    OS packages (pinned)
    constraints.txt               pip constraint file for transitive pins
    ansible.cfg                   the project ansible.cfg, injected into the EE
    Dockerfile.j2                 only if a custom build is genuinely required
    README.md                     what is in the image, how to build, how to promote
```

§18 names the first four. The additions are `constraints.txt` (to pin transitive
dependencies, without which a "pinned" requirements file is not pinned), `ansible.cfg`
(so the project config travels with the image rather than depending on a mount) and `README.md`.

### 2.1 `execution-environment.yml`

```yaml
version: 3

build_arg_defaults:
  EE_BASE_IMAGE: "quay.io/ansible/awx-ee:2.4.6"     # pinned, never a floating tag
  ANSIBLE_GALAXY_CLI_COLLECTION_OPTS: "--pre"      # pre-release, for provider collections
  ANSIBLE_GALAXY_CLI_ROLE_OPTS: "--pre"

additional_build_steps:
  prepend_galaxy:
    - COPY _build/requirements.yml /build/requirements.yml
    - COPY _build/ansible.cfg /etc/ansible/ansible.cfg
  append_final:
    - RUN /output/install-from-bindep && rm -rf /output/wheels

dependencies:
  galaxy: requirements.yml
  python: requirements.txt
  system: bindep.txt

images:
  base_image:
    name: "quay.io/ansible/awx-ee:2.4.6"
  python:
    requirements: requirements.txt
    constraints: constraints.txt
  galaxy: requirements.yml
  system: bindep.txt

additional_build_files:
  - src: ansible.cfg
    dest: configs

options:
  package_manager_path: /usr/bin/microdnf
  skip_ansible_check: false        # the collection's own sanity tests must run
  relax_passwd_permissions: false
  tags:
    - sba
    - platform
```

Three decisions in that file:

- **`ANSIBLE_GALAXY_CLI_COLLECTION_OPTS: --pre`** — the Azure, AWS and GCP collections ship much
  of their functionality in pre-release versions. Without `--pre` the EE silently omits
  modules. This is a real and easily-missed failure: the EE builds successfully and then the
  play fails at run time with "module not found".
- **`skip_ansible_check: false`** — the collection sanity tests are slow and are routinely
  disabled to save CI minutes. Disabling them means an EE that passes CI can still be broken.
  They are kept on for release builds and may be skipped for a local rebuild, with the release
  build being the one that counts.
- **The base image is pinned to a version** — not `latest`, per §31.

### 2.2 `requirements.yml` — collections

The single source of truth for collection versions. Used to build the EE, to run CI, and to
assert that a local environment matches the EE.

```yaml
---
collections:
  # ── ansible core-ish ────────────────────────────────────────────────
  - name: ansible.posix
    version: "1.5.4"
  - name: ansible.windows
    version: "2.3.0"
  - name: ansible.utils
    version: "2.10.1"
  - name: ansible.netcommon
    version: "6.1.0"

  # ── cloud providers ─────────────────────────────────────────────────
  - name: azure.azcollection
    version: "2.0.0"
  - name: amazon.aws
    version: "9.1.0"
  - name: google.cloud
    version: "1.5.0"
  - name: community.aws        # S3 for the state store
    version: "9.0.0"
  - name: community.general
    version: "9.0.0"
  - name: community.dns        # for the state store / DNS validation
    version: "8.0.0"

  # ── platform integrations ───────────────────────────────────────────
  - name: community.crypto     # x509, for runner certs
    version: "2.22.0"
  - name: ansible.builtin      # explicit: FQCN usage must be unambiguous
```

Rules: exact versions, no ranges, no `*`, comment-grouped, and every collection in the codebase
present here. The last one is enforced by a CI check that diffs the module namespaces used in
`roles/` against this file — a role using a module from an undeclared collection fails the
build, rather than failing at run time inside a production EE.

### 2.3 `requirements.txt` and `constraints.txt`

```txt
# requirements.txt — direct dependencies, pinned, hashed
pywinrm==0.5.0 \
    --hash=sha256:…
boto3==1.35.0 \
    --hash=sha256:…
azure-identity==1.19.0 \
    --hash=sha256:…
azure-mgmt-compute==33.0.0 \
    --hash=sha256:…
azure-mgmt-network==25.0.0 \
    --hash=sha256:…
google-cloud-compute==1.19.0 \
    --hash=sha256:…
requests==2.32.3 \
    --hash=sha256:…
passlib==1.7.4 \
    --hash=sha256:…
Jinja2==3.1.4 \
    --hash=sha256:…
cryptography==43.0.1 \
    --hash=sha256:…
PyYAML==6.0.2 \
    --hash=sha256:…
```

```txt
# constraints.txt — transitive pins. Generated by pip-compile, reviewed, committed.
ansible-core==2.17.6
urllib3==2.2.2
certifi==2024.8.30
...
```

`requirements.txt` alone is not a pin: it constrains direct dependencies, and the transitive
closure still floats. `constraints.txt` is what actually makes the build reproducible, and it is
why the design includes it beyond §18's list. Hashes are included so a compromised or
tampered package on the index cannot be substituted.

### 2.4 `bindep.txt`

```txt
gcc [platform:rpm]           # some azure/google SDKs compile small extensions
python3-devel [platform:rpm]
libffi-devel [platform:rpm]
openssl-devel [platform:rpm]
git                          # galaxy, and the state client
```

Minimal. Every entry is a build-time or runtime necessity, because each one widens the
container's attack surface. `git` is needed for galaxy; the compilers are needed only for the
handful of SDKs that build an extension, which is exactly why it is annotated.

### 2.5 Version consistency

The failure this prevents: "it worked locally, it fails in the EE" — a collection present in a
developer's `~/.ansible/collections` at a different version than the EE.

Three-point consistency, checked in CI:

```
  1. requirements.yml is the declared set
  2. ansible-galaxy collection install -r requirements.yml -p ./collections
     installs exactly that set
  3. the EE built from the same file contains exactly that set
  and: a collection namespace used in roles/ is present in requirements.yml
```

The last check is the one that catches a missing dependency at commit time instead of during a
production build.

---

## 3. Building and Promoting

```
  commit  ──▶ CI: build the EE
                tag: sba-ee:<short-sha>
                scan: trivy, checkov
                test: a Molecule scenario inside the built EE
                    │
                    ▼
              push to GHCR: sba-ee:<short-sha>  (+ digest)
                    │
                    ▼
  promotion: dev  ──▶ AAP dev project points at the digest
            nonprod ──▶ AAP nonprod project points at the digest
                    │
                    ▼
  production      ──▶ APPROVAL ──▶ AAP prod project points at the digest
```

| Environment | Reference | Rationale |
|---|---|---|
| dev | Tag `:latest-dev` **or** the commit digest | Iteration speed |
| nonprod | Commit digest | Reproducibility once past dev |
| prod | **Commit digest, always** | A mutable tag would let a collection update change a production build's toolchain |

The digest is recorded in `context.json` on every run and as a cloud tag (`EeDigest`) on every
server, so "which EE built this" is answerable from the server itself without a lookup
([I-12](architectural-decisions.md#3-cross-cutting-invariants)).

### 3.1 Promotion gates

| Gate | Requirement |
|---|---|
| Lint & security scan | Clean, on the EE contents as well as the source |
| EE smoke test | A Molecule scenario runs *inside the built EE* — not on the host runner. This is the only test that proves the EE is complete |
| Collection sanity tests | Pass (`skip_ansible_check: false`) |
| Trivy | No `CRITICAL` on the image; `HIGH` requires a recorded, expiring exception |
| Production promotion | Human approval, recorded |
| Digest immutability | The prod digest is never overwritten; a change creates a new digest |

**Running a scenario inside the built EE** is the gate that most projects skip and it is the one
that matters. A CI job that runs Molecule on the runner and then builds an EE has tested a
different environment from the one that will run in production, so the "it worked in CI"
guarantee is about a toolchain nobody uses.

---

## 4. Version Consistency Verification

Performed at three points, because each catches a different drift.

| Point | Check | Catches |
|---|---|---|
| **CI, on every PR** | Every module namespace in `roles/` is in `requirements.yml`; every collection has an exact version | A missing or floating dependency, at commit time |
| **EE build** | The installed set equals `requirements.yml`; sanity tests pass | A resolution conflict; a `--pre` omission |
| **Runtime, every run** | `context.json.sba_ee_digest` == the digest the runner reports; `ansible-galaxy collection list` inside the run is recorded in the result | A runner using the wrong image; an EE rebuilt in place |

The runtime check is the one that closes the loop. If a runner somehow runs an EE other than the
one the run-state record says, the mismatch is detected and recorded rather than silently
producing a build with an unattributable toolchain.

```yaml
# The runtime check, as a task in platform/contract_guard (shape)
- name: Confirm the execution environment matches the recorded digest
  ansible.builtin.stat:
    path: /etc/ansible/ee_digest
  register: sba_ee_digest_file

- name: Fail if the execution environment does not match the run record
  ansible.builtin.assert:
    that:
      - sba_ee_digest_file.stat.content | trim == sba_context.code.sba_ee_digest
    fail_msg: >-
      Execution environment digest mismatch. The run was recorded against
      {{ sba_context.code.sba_ee_digest }} but this runner reports
      {{ sba_ee_digest_file.stat.content | trim }}. Refusing to run: the build
      would not be reproducible.
    quiet: true
```

Failing closed here is the point. A build whose toolchain cannot be attributed is worse than no
build, because it looks successful and cannot be audited.

---

## 5. Runner Model

### 5.1 Why self-hosted

| Requirement | Hosted runner | Self-hosted |
|---|---|---|
| Reach private networks (SaaS VNets, private subnets, on-prem AD) | No | Yes |
| A cloud identity scoped to our subscriptions | Only via a broadly-scoped OIDC trust | Yes, instance identity |
| Steady capacity for a 2-hour prod build | 6-hour hosted limit, shared queue, no capacity guarantee | Yes |
| No inbound connectivity | Yes | Requires outbound-only (agent or ARC) |
| No artifact or credential residue | Yes | **Only with `--ephemeral`** |
| Ephemeral, clean state | Guaranteed | Must be configured |

The last two rows are why a self-hosted runner needs specific configuration. A long-lived
self-hosted runner accumulates `.git` credentials, installed packages, cached collections and
possibly credentials in the environment — a genuine risk given that it holds cloud credentials.

### 5.2 Configuration

| Setting | Value | Why |
|---|---|---|
| `--ephemeral` | Enabled | One job, then the runner deregisters. Nothing survives |
| `--labels` | `self-hosted, sba-<env>, linux, sba-ee` | Per-environment isolation; a `prod` job cannot land on a `dev` runner |
| `--runnergroup` | One per environment | Capacity and isolation per environment |
| `--no-default-labels` | Set, then explicit labels | Prevents accidental default-label matching |
| Installed software | The EE image only | No host-installed Ansible; the EE *is* the toolchain |
| Disk | Ephemeral OS disk, encrypted | Nothing persists |
| Inbound | **None** | Outbound-only to GitHub; no inbound port at all |
| Outbound | GitHub agent endpoint, cloud APIs, run-state store, target management ports | The minimum required set |
| Instance identity | A managed identity with **no standing cloud role** | OIDC per job only; a stolen runner has no cloud access |
| Patching | Image rebuild on a schedule; runners recreated on every job | A long-lived runner is a liability |
| Scale | Autoscaled (Actions ARC) per environment, scaled to zero | No idle cost, and a burst does not need pre-warming |
| Cleanup trap | Deregister, shred the disk, destroy the instance | A job must not leave a usable machine |

### 5.3 Network flow

```
  GitHub  ──(outbound from runner, agent tunnel)──▶  runner
  runner  ──(OIDC, job-scoped)──────────────────▶  Azure / AWS / GCP
  runner  ──(workload identity)────────────────▶  run-state store (private endpoint)
  runner  ──(WinRM 5986 / SSH 22)──────────────▶  build targets
  runner  ✗ inbound from anywhere
```

The runner has **no inbound** path. A build target cannot reach the runner, so a compromised
target cannot pivot to the build infrastructure, and the runner cannot be reached by anything
on the target network.

### 5.4 ARC versus self-hosted VMSS

| Aspect | Actions Runner Controller (ARC) | Self-hosted VMSS |
|---|---|---|
| Scale to zero | Yes, natively | Yes, with work |
| Ephemeral per job | Yes, natively | Manual configuration |
| Configuration drift | Low, template-driven | Higher |
| Complexity | Requires a Kubernetes cluster | Lower |
| Maturity for this pattern | Good, and improving | Long-established |

**Default: ARC on Kubernetes**, for scale-to-zero and per-job ephemerality. The fallback is a
VMSS with a startup script, which is acceptable where a Kubernetes platform is not available —
provided `--ephemeral` and the no-standing-role rules are enforced. Either way, the *security
properties* in [§5.2 ](#52-configuration) are the requirement, and the technology is a choice.

---

## 6. Runner Hardening

| Control | Requirement |
|---|---|
| No standing cloud permissions | The instance identity has no cloud role. The job acquires one via OIDC. A stolen runner yields no cloud access |
| Ephemeral | One job. The instance is destroyed afterwards |
| Outbound-only | No inbound security rule at all |
| No inbound SSH/RDP | Administration is out-of-band |
| No persistent disk | Ephemeral OS disk, encrypted at rest |
| No credential in the image | The image contains the EE and the runner agent only |
| No `sudo` for the runner process | The job runs as an unprivileged user |
| Filesystem | Read-only root where the platform permits; noexec on writable paths |
| Egress restricted | Only GitHub, the cloud APIs, the state store and the target management ports |
| No Docker socket | Mounting it would grant effective root on the host |
| `ACTIONS_RUNNER_HOOK_JOB_STARTED` / `_COMPLETED` | A hook enforces the OIDC claim's environment and the `no-secrets-in-inputs` assertion at run time, not only in CI |
| Log scrubbing | The runner's own logs are not a place where a secret may appear; there is none to appear |
| Patching | The image is rebuilt on a schedule; runners are single-use, so a vulnerable runner has a small window |
| Inventory | Tag every runner for cost and hygiene reporting; alert on an unexpected runner tag |

The two hooks are worth calling out. Every other control in that table is enforced at build or
provision time; the hooks enforce **at run time** that the job's OIDC claim names the expected
environment and that the inputs contain nothing secret. That closes the gap between "the CI
check passed when the workflow was written" and "the job that is running right now conforms".

### 6.1 Runner hook (sketch)

```bash
# .runner/hooks/started.sh — fails the job before it does anything
set -euo pipefail
EXPECTED_ENVIRONMENT="$(jq -r '.environment' "$GITHUB_EVENT_PATH" 2>/dev/null || echo unknown)"
CLAIMED_ENVIRONMENT="$(jq -r '.event.environment // "none"' \
                        "$RUNNER_TEMP/.runner_oIDC_claim.json" 2>/dev/null || echo none)"

if [ "$EXPECTED_ENVIRONMENT" != "$CLAIMED_ENVIRONMENT" ]; then
  echo "::error::Environment claim '$CLAIMED_ENVIRONMENT' does not match \
        the requested environment '$EXPECTED_ENVIRONMENT'."
  exit 1
fi

# A prod run must never be dispatched through the GitHub path [AD-09]
if [ "$EXPECTED_ENVIRONMENT" = "prod" ]; then
  echo "::error::Production builds are routed to AAP. Refusing to run."
  exit 1
fi
```

A hook cannot be edited by a workflow author without a code review, so this is a control at the
same trust level as the workflow itself, rather than an assertion inside the workflow that the
workflow author could remove.

---

## 7. Environments

| Environment | Base image | Python | Collections | Rebuild trigger |
|---|---|---|---|---|
| dev | `awx-ee` pinned | Pinned | Pinned + `--pre` | Every merge to `main` |
| nonprod | Same digest as prod candidate | Same | Same | Every `release/*` merge |
| prod | **Digest-pinned, promoted** | Same | Same | Release + approval |

The intent is that **nonprod and prod run the identical digest.** If they differ, nonprod is not
validating what prod will run, and the entire reason for having a nonprod environment is lost.
This is a stricter requirement than "both are pinned" and it is the one that actually provides
assurance.

---

## 8. Size and Performance

| Item | Target | Notes |
|---|---|---|
| EE image | 1.5–2.5 GB | Three cloud SDKs plus three provider collections is inherently large |
| Build time | 8–15 min | Acceptable; cached layers help |
| Pull time (first job on a runner) | 3–8 min | Mitigated by keeping a warm runner pool; pull once per job for a single-use runner is the trade-off for ephemerality |
| Job overhead | ~30 s | EE startup |
| Build target impact | None | The EE runs on the controller, not the target |

**The pull-versus-warm-pool trade-off is worth stating honestly.** A single-use runner must pull
the EE on every job, adding 3-8 minutes to a 35-60 minute build. Two mitigations: keep a small
warm pool (which slightly weakens ephemerality, so keep the warm pool for dev/nonprod and use
cold single-use for prod), and prefer a warm *image* on the instance rather than a warm runner
— the image is on the local disk, so "cold runner" still means no 5-minute pull.

The design answer: the runner instance boots from an image that **already contains the EE**, and
the job runs the image's Ansible. Then a single-use runner has no pull cost at all, and
ephemerality is preserved. The registry remains the source of truth and the digest is verified
at run time by [§4 ](#4-version-consistency-verification).

---

## 9. Verification Checklist

Run at CI time on every EE build, and re-run for a release candidate.

```
  [ ] ansible-lint clean on the repository
  [ ] ansible-playbook --syntax-check on every playbook
  [ ] ansible-playbook --list-tasks on every playbook  (catches import errors)
  [ ] every module namespace in roles/ is declared in requirements.yml
  [ ] every collection in requirements.yml has an exact version (no ranges, no *)
  [ ] every Python package in requirements.txt is pinned AND hashed
  [ ] constraints.txt is up to date and reviewed
  [ ] bindep.txt entries are minimal and each is justified
  [ ] the base image is pinned to an exact version
  [ ] collection sanity tests pass (skip_ansible_check: false)
  [ ] the installed collection set == requirements.yml (diff, no extras, none missing)
  [ ] pip-audit: no known-vulnerable package
  [ ] trivy on the image: no CRITICAL
  [ ] gitleaks on the image layers
  [ ] a Molecule scenario runs INSIDE the built EE
  [ ] ansible.builtin.* is the only namespace not from a declared collection
  [ ] ansible.cfg is present and correct inside the EE
  [ ] the digest is recorded and immutable
  [ ] the runtime digest check ([§4](#4-version-consistency-verification)) is in place
  [ ] nonprod and prod reference the same digest
```

---

## 10. Next

- The pipeline that builds and promotes this: [cicd-pipeline.md](cicd-pipeline.md)
- Runner network posture: [security-architecture.md §8.1 ](../security/security-architecture.md#81-platform-network-posture)
- Collection usage rules per role: [role-dependency-model.md §8 ](role-dependency-model.md#8-naming-and-layout-conventions)
- Dependency scanning: [cicd-pipeline.md §4 ](cicd-pipeline.md#4-mandatory-checks)
