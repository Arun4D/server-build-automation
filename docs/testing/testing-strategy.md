# Testing Strategy

Status: **Phase 1 — Proposed**

The test pyramid for a platform whose output is production infrastructure: what is tested, at
which layer, with what fixture, and what is deliberately *not* mocked.

Related: [../architecture/cicd-pipeline.md](../architecture/cicd-pipeline.md),
[../architecture/idempotency.md](../architecture/idempotency.md).

---

## 1. The Core Problem

Most of this platform's output is a production server, and a bug in it is not a failed test
assertion — it is a mis-provisioned payment gateway, a missing CMDB record, or a duplicate DNS
entry. Two consequences shape the whole strategy:

1. **Push as much verification as possible below the level where infrastructure is created.** The
   resolver, the naming engine, and the TagMapper are pure functions. They can be tested
   exhaustively, at speed, for free. Every behaviour that can be expressed in one of them
   should be, so that the cloud-touching code has as little to do as possible.
2. **Test the failure paths harder than the success paths.** A build that works is a build
   someone has already validated by using it. A build that fails halfway, that re-runs, that
   finds a pre-existing resource, or that cannot reach a domain controller is where the real
   defects are, and it is exactly where a happy-path-only test suite gives false confidence.

### 1.1 The testability rule

> A behaviour is implemented in a pure function if it can be, and the function is tested
> exhaustively. Behaviour that cannot be pure is tested at the narrowest possible boundary, with
> the cloud mocked and everything above it real.

The second half is the important constraint. A test that mocks the resolver, the naming engine
and the tag mapper and asserts that a playbook calls `azure_rm_virtualmachine` proves almost
nothing: it proves the playbook calls the module, which a `--syntax-check` also does.

---

## 2. Test Layers

| Layer | What | Runs in | Duration | On PR? |
|---|---|---|---|:--:|
| L1 | Pure unit tests: resolver, naming, TagMapper, image selection, policy | Local, no containers | <30 s | yes |
| L2 | Contract tests: JSON schema positives and negatives | Local | <5 s | yes |
| L3 | Static analysis: lint, syntax, list-tasks, architecture gates | Local | <1 min | yes |
| L4 | Molecule role tests, in a container EE | Docker | 5-15 min | yes |
| L5 | Playbook integration, mocked cloud APIs | Container EE | 10-20 min | yes |
| L6 | Sandbox cloud integration | Real cloud, tagged, auto-expired | 30-60 min | merge to main; nightly |
| L7 | E2E: ServiceNow → engine → cloud → CMDB | Full stack | 60-90 min | nightly; pre-release |
| L8 | Non-functional: idempotence, cross-engine parity, canary leak, OIDC negatives | Mixed | varies | nightly; per release |

**L1-L3 are the merge gate. L4-L5 are the merge gate too.** L6-L8 run on `main` and nightly.
Requiring L6 for a merge would make a 60-minute PR wait, and that pressure produces the batching
and rubber-stamping that makes a slow pipeline dangerous in the first place
([cicd-pipeline.md §7 ](../architecture/cicd-pipeline.md#7-observability-and-pipeline-operations)).

---

## 3. L1 — Pure Unit Tests

The highest-value tests in the project, because they are the only ones that can be exhaustive.

### 3.1 The resolver

```python
# tests/unit/test_resolver.py
def test_undefined_variable_in_application_entry_fails():
    with pytest.raises(ResolutionError) as e:
        resolve(config, RequestContext(**base_context))
    assert "undefined_variable" in str(e.value)
    assert e.value.detail_source == "$.applications.payments.vm_size"

def test_max_inheritance_depth_enforced():
    with pytest.raises(ResolutionError) as e:
        resolve(config_with_6_level_chain(), RequestContext(**base_context))
    assert "max_inheritance_depth" in str(e.value)

def test_resolution_is_order_independent():
    """Two different key orderings in the config must resolve identically."""
    a = resolve(config_keys_sorted(), RequestContext(**base_context))
    b = resolve(config_keys_shuffled(), RequestContext(**base_context))
    assert a == b
```

| Property | Test |
|---|---|
| Precedence order | Each layer overrides the one below it |
| Depth limit | A 5-level chain resolves, a 6-level chain fails |
| Cyclic inheritance | Detected and reported with the cycle path |
| Undefined variable | Fails, with the JSON pointer |
| No implicit defaults | Every leaf has a resolvable source |
| Cloud is not a merge dimension | The same `apply_to` value for azure/aws in one file is a `CLOUD_LEAK` |
| Determinism | Key order does not change the result |
| Purity | A second call with the same input returns the same value, and no I/O occurred |

**Order-independence and purity are the two that catch real bugs.** A resolver whose result
depends on dictionary iteration order will produce a different `context.json` for the same
request depending on how the YAML happened to be written, which makes idempotency's
`CONFIGURATION_DRIFT_IN_RUN` check fire on a no-op re-run for no reason. Both are cheap to test
and neither is obvious from reading the code.

### 3.2 Naming

The most rule-dense component, and the one with a hard external constraint.

| Test | Assertion |
|---|---|
| `short_name` ≤ 15 | Generated names never exceed 15 |
| `short_name` matches the computer-name pattern | `^[a-z][a-z0-9-]{0,14}$` |
| Collision on an existing name | The counter advances; the result is still ≤ 15 |
| Collision exhaustion | `NAME_UNRESOLVABLE` or a `NAME_TAKEN` escalation, never a loop |
| `fqdn` per RFC 1123 | Each label ≤ 63, total ≤ 253, no leading/trailing hyphen |
| `fqdn` within the app's domain scope | An out-of-scope value is rejected |
| Case | Always lowercase, on every cloud |
| Determinism | The same run context yields the same names — no wall clock, no random |
| Counter determinism | The counter is derived from the queryable scope, not from a process-level increment |

The last row is a subtle and important one. A counter held in memory produces a different name
on a re-run in a different process, which breaks [idempotency.md §4 ](../architecture/idempotency.md#4-create-or-adopt)
completely — the lookup by name would find nothing, and the platform would create a second
server with the same intent. The counter must be a pure function of the scope, e.g. a hash of
`(app_code, environment, region, scope)`.

### 3.3 TagMapper

The most provider-divergent component, and the one that would otherwise need three real cloud
accounts to test.

| Test | Assertion |
|---|---|
| GCP label lowercase | A mixed-case value is lowercased or moved to an annotation |
| GCP label 63 chars | A longer value is truncated or moved to an annotation |
| GCP label charset | An invalid character causes the key to go to an annotation |
| Azure forbidden characters | `< > % & \ ? /` cause a `METADATA_REJECTED` at **resolution** |
| AWS tag key 128 | A longer key fails |
| Count limits | Exceeding the provider's count is `METADATA_LIMIT_EXCEEDED` |
| `sba_instance_id` present in the label set on **every** provider | This is `AD-11`, and it is an assertion in the test suite, not a comment |
| Transformation recorded | Every normalisation appears in `metadata_transformations` |
| Idempotent | Mapping the same input twice gives the same output |
| Golden files | The full tag set for each provider is compared to a committed JSON file |

The golden-file test is what makes the TagMapper safe to change. A change that silently changes a
cost-centre label from `FIN-1234` to `fin-1234` would break every cost report in the estate, and
no unit assertion would notice. A diff in a committed golden file is unmissable in review.

### 3.4 Image selection

| Test | Assertion |
|---|---|
| A pinned version is required | An unpinned entry is `IMAGE_REFERENCE_UNPINNED` |
| An expired image | `IMAGE_EXPIRED`, before any resource is created |
| A revoked image | `IMAGE_REVOKED`, immediately |
| A region missing from an AWS entry | `IMAGE_NOT_FOUND` for that region |
| The OS family matches the role's expectations | A Linux role with a Windows image fails |
| The generation matches | Gen1 requested, Gen2 available |
| Selection is deterministic | Same inputs, same image |

### 3.5 Policy

| Test | Assertion |
|---|---|
| Batch size over the floor | `POLICY_VIOLATION` with the floor and the limit |
| A disallowed size | Rejected, with the allowed list |
| A disallowed region | Rejected |
| Encryption below the policy floor | Rejected |
| A missing data classification | Rejected |
| An active change freeze | `CHANGE_FREEZE_ACTIVE` |
| A policy that allows everything | Still requires the mandatory keys to be present |

The last row is the one that catches a policy file that was written permissively by accident. A
policy that checks nothing is not neutral — it disables the gate for whatever the catalogue
happens to contain, which is the failure mode the gate exists to prevent.

### 3.6 Property-based tests

Where the input space is too large to enumerate.

```python
from hypothesis import given, strategies as st

@given(
    app=st.text(min_size=1, max_size=8, alphabet=st.characters(
        whitelist_categories=("Ll", "Nd"), whitelist_characters="-_")),
    env=st.sampled_from(["dev", "nonprod", "prod"]),
)
def test_short_name_always_within_limit(app, env):
    ctx = generate_name(app_code=app, environment=env, region="eu-west-1",
                        scope="payments-app", start_index=0)
    assert len(ctx.short_name) <= 15

@given(st.text(alphabet=st.characters(whitelist_categories=("Lu", "Ll", "Nd",
         "Pc", "Zs", "Po")), max_size=200))
def test_fqdn_is_always_rfc1123(value):
    """Any input either produces a valid FQDN or a clean error. Never an invalid FQDN."""
    result = build_fqdn(hostname=value, domain="corp.example.com")
    assert result.ok or result.error_code in {
        "FQDN_INVALID", "FQDN_TOO_LONG", "LABEL_TOO_LONG"
    }
```

The property test above is the one worth writing: the useful property is not "every valid input
works" but "**no input ever produces an invalid FQDN**". A DNS record with an invalid name is a
production outage, and a property test over the full character space is the only way to be
confident that no input slips through.

### 3.7 Mutation testing

On the resolver and TagMapper, mutation testing is worth the effort, because a surviving mutant
there is a real defect:

| Mutant | Must be killed by |
|---|---|
| `>` becomes `>=` in the ≤15 check | `test_short_name_always_within_limit` |
| Layer order swapped in the precedence loop | The precedence-order test |
| GCP label length 63 becomes 512 | The TagMapper golden files |
| The `sba_instance_id` label check removed | The `sba_instance_id`-in-labels assertion |
| Uppercase normalisation removed | The GCP lowercase test |

If a mutant survives, that is a missing test, and the mutation report says which. The effort is
justified here and nowhere else in the codebase.

---

## 4. L2 — Contract Tests

| Suite | Input | Expected |
|---|---|---|
| Valid contract | Every field correct | Accepted |
| Unknown field | `{"cloud": "azure", "admin_password": "x"}` | `CONTRACT_FORBIDDEN_FIELD` — **never ignored** |
| Wrong type | `count: "four"` | `SCHEMA_INVALID` |
| Enum violation | `cloud: "ONPREM"` | `UNSUPPORTED_ENUM_VALUE` |
| Out of range | `count: 500` | `SCHEMA_INVALID` |
| Missing required | `application` absent | `SCHEMA_INVALID` |
| Unknown version | `schema_version: "99.0"` | `CONTRACT_VERSION_UNSUPPORTED` |
| `additionalProperties: false` | Any unknown field | Rejected |
| Corpus | 200 generated malformed contracts | All rejected, none crash the validator |
| **Fuzz** | Random bytes, wrong types, deeply nested | No unhandled exception. **A crash is a failure** |

The last row is the one most often omitted. A schema validator that throws on a malformed input
instead of returning a validation error turns a requester's typo into a 500, and an attacker into
a way to consume a worker. The corpus test asserts the validator *always* returns a result.

**Nested-field rejection is a security test.** A contract with `additionalProperties: false` at
the top level but not inside a nested object accepts `{"sba": {"admin_password": "x"}}` unless
the nested object is also closed. The corpus includes a nested-extra-field case for exactly this
reason.

---

## 5. L3 — Static Analysis

| Check | Tool | What it protects |
|---|---|---|
| Syntax | `ansible-playbook --syntax-check` | Broken imports |
| Task enumeration | `ansible-playbook --list-tasks` | Unresolvable includes at runtime |
| Ansible best practice | `ansible-lint` | FQCNs, `name`, `changed_when`, state |
| YAML | `yamllint` | Indentation, line length |
| Workflows | `actionlint` | Expression errors in `${{ }}` |
| Python | `ruff`, `mypy` | The resolver and the state client |
| Shell | `shellcheck` | Any shell in the roles |
| Action SHA pinning | custom | Supply chain |
| Architecture gates | custom | `I-1`..`I-8`, `AD-08`, `AD-12`, `AD-15` |

The architecture gates are listed again here because they are the only layer that protects the
decisions rather than the code. A change that moves a provider module into a non-provider role
passes every functional test and breaks `R-08`.

---

## 6. L4 — Molecule Role Tests

Container-based, so they run on any PR without a cloud account.

```yaml
# roles/cloud/azure_vm/molecule/default/converge.yml
- name: Provision
  ansible.builtin.include_role:
    name: sba.cloud.azure_vm
  vars:
    sba_instance_id: "{{ molecule_id }}"

- name: Assert the ownership tag was applied in the create call
  ansible.builtin.assert:
    that:
      - azure_calls | selectattr('tags', 'defined')
                 | selectattr('tags.sba_instance_id', 'defined') | list | length > 0
      # The FIRST create call must already carry the tag. A separate CreateTags
      # afterwards is a design violation, not a style preference.
```

### 6.1 Per-role scenarios

| Role | Scenarios |
|---|---|
| `resolve_configuration` | Success, missing entry, precedence conflict, cycle |
| `naming` | Generate, collide, exhaust, FQDN validation |
| `policy_gate` | Allow, deny each rule, freeze active |
| `image_resolver` | Pinned, expired, revoked, region-missing |
| `report` | Success artifact, failure artifact, partial artifact |
| `cloud/*` | Create, adopt, converge, immutable-mismatch, ambiguous, delete |
| `image/*` | Resolve, pinned enforcement |
| `os/*` | Idempotence on a minimal Ubuntu, plus a real Windows image |
| `post_build/*` | All run independently against a stubbed state store |

### 6.2 Idempotence is mandatory in every role scenario

```yaml
- name: Second converge
  ansible.builtin.include_role:
    name: sba.cloud.azure_vm
  vars:
    sba_instance_id: "{{ molecule_id }}"

- name: Assert the second run changed nothing
  ansible.builtin.assert:
    that:
      - second_run.changed | length == 0
```

**A role that cannot pass this is not finished.** `changed == 0` on a second run is the single
most valuable assertion in the entire suite, because it is a direct test of
[G-3](../architecture/idempotency.md#3-guarantees) and [G-4](../architecture/idempotency.md#3-guarantees), and because it is
cheap. A role that reports `changed` on every run will, in production, produce a permanently
"drifting" estate, a full run-state history on every execution, and an operations team that stops
reading the diff.

### 6.3 Mocking rules

| Mock | Never mock |
|---|---|
| Cloud APIs | The resolver, the naming engine, the TagMapper, the policy gate |
| The run-state store | The run context structure itself |
| ServiceNow | The mapping from run result to callback |
| The OS package repo | The actual `os_config` tasks on a real guest |

The rule is that **anything the platform computes is real; anything the platform calls out to is
mocked.** Mocking the resolver would make the test assert that a fixture was used, which is what
`--list-tasks` already does, while missing the case where the resolver is wrong.

---

## 7. L5 — Playbook Integration

Full playbooks, container EE, mocked cloud and ServiceNow APIs. This is where the *stage
sequencing* is tested, which no role-level test can do.

| Scenario | Asserts |
|---|---|
| Full happy path, 2 servers | Stage order; 2 instances; tags on both; artifacts written |
| Host 1 fails at `domain_join` | Host 2 continues; `PARTIAL`; DNS for host 2 only; CMDB for host 2 |
| Failure at `validate` | Nothing created. Not one resource |
| Failure at `policy_gate` | Nothing created |
| Failure at `provision` after the create | Retained, `PARTIAL`, resources recorded |
| Re-run after a partial failure | Adopted, not created. `instance_count` unchanged |
| Crash between create and record | Simulated; the next attempt's tag lookup finds the instance |
| Ambiguous lookup (two matches) | `AMBIGUOUS_RESOURCE`. No mutation |
| Lock contention | Second run `QUEUED`, not failed |
| Every stage, in isolation | Runs correctly with only its predecessor completed. This is what makes stage re-entry real |
| Two runs, same app, different regions | Correct subnet, zone, and name scope per region |
| `count: 8` | Eight instances, `serial: 1`, no cross-contamination |

The "every stage in isolation" scenario is the one that most directly tests
[AD-01](../architecture/architectural-decisions.md#ad-01-single-entry-playbooks--staged-re-entry). If
`domain_join` can be run against a completed `os_config` without a re-run of anything before it,
then stage re-entry genuinely works and the platform does not need a second playbook.

### 7.1 Cloud API mock fidelity

A mock that returns a generic `200` for everything will pass tests that a real cloud would fail.
The mocks must therefore reproduce the specific behaviours this platform depends on:

| Behaviour the platform depends on | Mock must reproduce |
|---|---|
| Tag-propagation eventual consistency | The first filtered read returns empty; the second returns the instance |
| Ambiguous delete | `NotFound` on a second delete |
| Rate limiting | `429` for the first N calls, then success |
| Slow provisioning | `pending` for M polls, then `running` |
| Immutable attribute rejection | `409` on a zone change |
| Quota | `QuotaExceeded` for a specific size/region combination |
| Asynchronous deletion | `200` on delete while the resource still appears in reads |

The first row is the one to insist on. A mock that returns the instance immediately on the first
read would let an implementation that creates on a stale read pass its tests, and that
implementation duplicates servers in production. The mock's job is to reproduce the specific
pathology the design defends against.

---

## 8. L6 — Sandbox Cloud Integration

Real cloud resources in a sandbox subscription/project, created by a scheduled or `main`-triggered
workflow.

| Provider | Sandbox | Cost control |
|---|---|---|
| Azure | A dev RG per run, with an Azure Policy that caps the instance count | Tags + auto-expiry RG |
| AWS | An account with an SCP capping the instance type and count | Tags + a Lambda expiry |
| GCP | A project with a budget alert and a per-project instance quota | Labels + a scheduled cleanup |

Every resource carries the platform tags **and** a `sba_expiry` tag. A scheduled cleanup deletes
anything past its expiry, so a failed test run cannot leak cost indefinitely. This is the same
"retain by default" policy as production, and it is the right one: a cleanup that deletes on a
timer must be obviously safe, and a tag-scoped, expiry-scoped delete is easier to reason about
than a heuristic.

Scenarios: the same set as L5, against a real API, plus:

| Scenario | Asserts |
|---|---|
| Real tag propagation | The read-back in the GCP `tags_converge` actually catches a missing label |
| Real eventual consistency | The bounded read retry is genuinely needed |
| Real quota behaviour | `QUOTA_EXCEEDED` is produced by a real quota, and the message is actionable |
| Real CMK behaviour | Disk encryption with a customer-managed key works end to end |
| Real privileged admin | The Azure Windows create with a password from the credential store works |
| Real OS configuration | `os_config` against a real guest, and idempotence on a second run |

The last row is the one that cannot be mocked at all, and it is the most likely place for a real
defect: package names differ between distributions, a Windows feature has a different name than
expected, and a `winrm` setting behaves differently on a domain-joined host than on a standalone
one. A container cannot catch any of it.

---

## 9. L7 — E2E

The full path, in a sandbox, nightly and before every release.

```
  ServiceNow RITM (test record)
        │  OIDC
        ▼
  Adapter  →  GitHub workflow_dispatch  ┐
   or     →  AAP job launch             ├→ run_context.json
        ▼                                ┘
  Resolver → pre-flight → policy gate
        ▼
  Cloud (sandbox) → OS config → domain join → agents → DNS → CMDB
        ▼
  run_result.json  →  callback  →  RITM state
        ▼
  Assertions
```

| Assertion | Why it matters |
|---|---|
| The RITM reaches `Complete` | The happy path |
| The CMDB record carries `sba_instance_id` | `AD-05` end to end |
| The instance carries the same `sba_instance_id` | The join key survives the whole pipeline |
| The DNS record resolves to the instance | The actual outcome a requester cares about |
| Every sink is free of secrets | The canary test |
| Both engines produce the same `context.json` | `AD-01` and `AD-21` |
| A destroy request removes everything | The full teardown, not just the VM |
| A re-run after a mid-pipeline failure converges | The idempotency claim, proven once end to end |

**The canary leak test.** A synthetic canary value, e.g.
`SBA-CANARY-7f3a2b9c4d5e6f70`, is placed in each of the sinks where a secret *would* go if the
implementation were wrong: the generated contract, the dispatch payload, the run context, the
state store, the artifacts, the callback, the cloud metadata, the ServiceNow record, the CMDB
record, and the log output. After the run, every sink is searched for it.

A canary found anywhere is a hard pipeline failure, not a warning. The test is cheap, it needs no
real secret, and it is the only automated check that directly verifies `AD-15` at the level where
it matters.

---

## 10. L8 — Non-Functional

### 10.1 Idempotence under chaos

The strongest test in the suite, and the one that most often finds real defects.

| Injection | Expected behaviour |
|---|---|
| Kill the process 5 s after the create call, before the record | Next attempt's tag lookup finds the instance and adopts it |
| Kill during the DNS record creation | The record exists; the next attempt converges it |
| Kill during the CMDB upsert | Exactly one record; no duplicate |
| Kill during the callback | The callback is retried; the RITM ends up correct |
| Lock TTL expires mid-stage | Takeover; re-read state; no duplicate mutation |
| Cloud returns a timeout on a create that succeeded | Read-back finds it; adopted |
| State store is briefly unavailable | `STATE_STORE_UNAVAILABLE`; retry; no mutation attempted before state is durable |
| An instance with the tag already exists (adoption) | Adopted, verified, converged. Zero new resources |

The assertion after every injection is the same: **the total count of resources carrying the
`sba_instance_id` is exactly one, and the CMDB has exactly one record.** A chaos test that only
checks the run reached a terminal status would pass an implementation that created three servers.

### 10.2 Cross-engine parity

```bash
# Same contract, both engines, same EE digest
sha256sum dev-artifacts/context.json  aap-artifacts/context.json
# The two files must be byte-identical.
```

Any difference is a defect in one of the engines' context construction. This is the automated
form of `AD-01`'s intent, and it is worth doing byte-for-byte rather than semantically, because
a byte difference is unambiguous in a CI log and a semantic comparison needs an explanation of
what was normalised.

### 10.3 OIDC negative tests

| Test | Expected |
|---|---|
| A `pull_request` ref assuming the prod role | Denied |
| A non-default branch assuming the dev role | Denied |
| A wrong `sub` claim | Denied |
| A wrong audience | Denied |
| An expired token | Denied |
| A replayed token (jti) | Denied |
| The prod role attempting a `Tag` delete | Denied |
| The read-only identity attempting a create | Denied |
| The run identity touching a resource with a different `sba_instance_id` | Denied |

Each is a one-line cloud policy change and an automated assertion. A trust policy that is
configured correctly and never tested is a trust policy that will be broken by the next person to
edit it.

### 10.4 Privilege and blast-radius tests

| Test | Assertion |
|---|---|
| The dev identity can reach only the dev subscription/project/account | The others are denied |
| The prod identity cannot write to the dev estate | Denied |
| A build cannot create a resource without the ownership tag | Denied by Azure Policy / SCP / org policy |
| A run cannot touch a resource with a different `sba_instance_id` | Denied by the tag/label condition |
| The `svc-sba-destroy` identity cannot delete shared networking | Denied by the per-server RG boundary ([azure.md §2 ](../architecture/cloud/azure.md#2-resource-group-layout)) |

### 10.5 Performance

| Metric | Target | Rationale |
|---|---|---|
| L1 suite | <30 s | Fast enough to run on every save |
| L3 static | <60 s | A slow gate gets bypassed |
| `validate` + `policy_gate` | <10 s | A pre-flight that takes a minute feels like a hang |
| Stage (network-bound) | <2 min | |
| Stage (domain join) | <10 min | AD replication is the floor |
| L4 Molecule suite | <15 min | Long enough to be a real check, short enough to be a merge gate |
| Full E2E | <90 min | Nightly |

The "feels like a hang" row is not a joke. Pre-flight is the first thing a requester experiences
after submitting, and its duration sets their expectation for the whole build. Fast pre-flight,
long build is the right shape; slow pre-flight makes the platform feel broken.

### 10.6 Security testing

| Test | Frequency |
|---|---|
| `gitleaks` over the full history | Every PR |
| `bandit`, `semgrep` (Ansible and Python) | Every PR |
| `pip-audit` | Every PR |
| `trivy`, `checkov` on the EE image | Every EE build |
| `dependency-review` | Every PR |
| An external penetration test | Annually, and before the first production use |
| An IAM permission review against `AUTHZ.md` | Quarterly, and on any new grant |
| A tag-integrity audit (no resource without the ownership tag) | Daily, paged on non-zero |

---

## 11. Coverage

| Component | Target | Notes |
|---|---|---|
| `sba_resolver` | 100% branch, plus mutation | Pure. No excuse for anything less |
| `sba_naming` | 100% branch, plus property tests | |
| `sba_tag_mapper` | 100% branch, plus golden files | |
| `sba_state` | 90% | The CAS and the retry paths matter most |
| `sba_report` | 90% | |
| Provider roles | 80% + the mandatory idempotence scenario | Most of the remainder is SDK call shape |
| OS roles | 80% | A real guest is needed for the rest ([§8 ](#8-l6--sandbox-cloud-integration)) |
| Playbooks | Stage-sequencing scenarios, not line coverage | Line coverage of a playbook measures nothing useful |

**The resolver at 100% branch coverage is not a stretch goal.** It is a few hundred lines of pure
Python, and it decides what production looks like. Every branch is a decision somebody could get
wrong, and none of them can be discovered by running the thing.

---

## 12. Fixtures and Test Data

| Fixture | Location | Notes |
|---|---|---|
| Golden resolution files | `tests/fixtures/golden/*.json` | Regenerated per configuration change; **the diff is reviewed** ([cicd-pipeline.md §5.2 ](../architecture/cicd-pipeline.md#52-golden-resolution-files-as-promotion-control)) |
| Contract corpus | `tests/fixtures/contracts/{valid,invalid}/` | Including the nested-extra-field case |
| Injection corpus | `tests/fixtures/contracts/injection/` | `$(...)`, `; rm -rf`, backticks, `${jinja}`, newline, CRLF, a null byte, a 1 MB string |
| Tag matrix | `tests/fixtures/tags/{azure,aws,gcp}.json` | Per-provider expectations |
| Naming corpus | `tests/fixtures/naming/` | Collision, exhaustion, Unicode, emoji, 15-char boundary |
| Mock API specs | `tests/mocks/{azure,aws,gcp}/` | Including the eventual-consistency behaviour |
| A ServiceNow test record template | `tests/fixtures/servicenow/` | Created and destroyed by L7 |

**Fixtures are golden files, and a golden-file diff is a review artefact.** The `injection`
corpus is the one to keep growing: a resolver or a template that passes `$(...)` through to a
shell is a remote code execution path, and the corpus is the only automated defence.

---

## 13. What Is Not Tested, and Why

| Not tested | Why |
|---|---|
| A real cloud API's correctness | It is not ours. We test our handling of it |
| A real AD domain in CI | Too slow and too fragile. Covered in L6/L7 against a test domain |
| WinRM certificate internals | Covered by connecting to a real host in L6 |
| The full ServiceNow approval UI | The adapter is tested against the API; the UI is ServiceNow's |
| Business approval correctness | A human approves; the platform enforces that an approval exists before Stage 1 |
| "Is this the right server to build?" | A business question. The platform resolves and validates; the requester decides |
| Cost | A monthly FinOps review, not a test |

The last two rows are the honest boundary of what this platform can verify. The testing strategy
can prove that a request produces the correct infrastructure. It cannot prove that the request was
the right one to make, and no amount of test coverage changes that.

---

## 14. Next

- Pipeline stages and check configuration: [../architecture/cicd-pipeline.md](../architecture/cicd-pipeline.md)
- Idempotency guarantees: [../architecture/idempotency.md](../architecture/idempotency.md)
- Testing standards per role: [../architecture/role-dependency-model.md](../architecture/role-dependency-model.md#9-standards-applied-to-every-role)
- Phase exit criteria: [../roadmap.md](../roadmap.md)
