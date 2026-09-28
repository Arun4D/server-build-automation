# Schemas

JSON Schema for every document that crosses a process boundary.

> **Scope in this release: GCP, on GitHub Actions.** ServiceNow, AAP/AWX, Azure and AWS are out of
> scope for now. The four files below are self-contained and reference nothing outside themselves,
> so adding a second engine or a second provider is an additive change to an enum plus a
> conditional — not a structural one.

| File | Validates | Produced by |
|---|---|---|
| `business-request.schema.json` | The engine-neutral, provider-neutral, business-only contract. 9 required fields, 56 forbidden properties | The requester, via `workflow_dispatch` or a direct POST |
| `run-context.schema.json` | The resolver's output: the single effective configuration for one run | `scripts/resolve_configuration.py` |
| `stage-result.schema.json` | One stage's result, one entry per host | Each stage, via `roles/platform/report` |
| `run-result.schema.json` | The final result artifact, rolled up across stages and hosts | `roles/platform/report` |

**These files are contracts, not documentation.** They are validated in CI, validated again at the
trust boundary before anything acts on them, and their `schema_version` is the version referred to
by [AD-20](../docs/architecture/architectural-decisions.md#ad-20-additive-schema-versioning-only).

## Why four, not six

The original plan had six, adding a `service-request` and a `callback` schema for the ServiceNow
boundary. With ServiceNow and AAP out of scope there is no caller to wrap and nothing to call back,
so both were dropped rather than stubbed. Two things were worth keeping from them, and both are
already here:

- The request envelope **is** the contract. A `workflow_dispatch` input or a direct REST body is
  `business-request.schema.json` verbatim, so there is no second shape to keep in sync and no
  wrapper whose validation could disagree with the payload it carries.
- Results are **pulled from the run-state store**, not pushed. The store is the source of truth
  (AD-04) and the artifact is the delivery mechanism (AD-14), so a callback schema would have been a
  second, optional path to a fact that already has a durable one — and the hardest kind of thing to
  make idempotent correctly.

Reintroducing either is additive, and the boundary to model is then the store, not a request record.

## `additionalProperties: false` at every level

Not only at the top level. A schema that closes the root but leaves a nested object open accepts:

```json
{ "cloud": "GCP", "credentials": "hunter2" }
```

unless the nested object is also closed. The negative-case corpus in
`tests/fixtures/contracts/invalid/` includes exactly this shape, because it is the one that gets
missed.

A schema that tolerates unknown fields is a schema that will eventually accept something dangerous.

**The three exceptions are deliberate, and all three are free-form *value* maps whose keys are
constrained by `propertyNames` and whose values are constrained by a schema** — not open objects:
`metadata.labels` (GCP labels), `metadata.annotations` (the complete copy), and `os_build.sysctl`.
The labels and annotations maps *cannot* enumerate their keys without becoming wrong, because the
whole point of AD-11 is that the canonical key set is open and a TagMapper projects it. Their
`propertyNames` patterns are the API's own limits, so a violation is a resolution error naming the
key rather than a 400 from the API.

## Contract rules

| Rule | Reason |
|---|---|
| `additionalProperties: false` everywhere | An unknown field is an error, not something to ignore |
| Every field has a `description` | A schema nobody can read is a schema nobody will use correctly |
| Enums, never free strings | `cloud`, `environment`, `os_family`, `stage` and `code` are closed sets. An unknown value is `UNSUPPORTED_ENUM_VALUE` |
| Bounded numerics | `count` has a maximum. An unbounded integer is a denial-of-service vector |
| Bounded strings, by pattern | `short_name` is capped at 15 by a regex, not a comment, because 15 is a NetBIOS limit and a limit that is only documented is a limit that gets exceeded |
| `const` for invariants, not enums | `cloud_role`, `on_failure`, `external_ip`, `zone_semantics` and `execution_engine` are `const`. An `enum` of one value invites someone to widen it without noticing they changed a control |
| No business logic in the schema | A schema validates shape, not policy. Policy is [configuration-resolution §10](../docs/architecture/configuration-resolution.md#10-policy-gate) |
| Additive within a major version | A consumer can ignore a field it does not know; it cannot ignore a removed one |

That `const`-for-invariants rule is worth its own line, because `zone_semantics:
deployment_locality_only` is the one that matters most. A GCP zone is a deployment locality with
**no** capacity-isolated failure-domain guarantee. Encoding that as a `const` means a future change
to the zone policy is a schema diff in a pull request, where someone will read it, rather than a
documentation change nobody will. See [gcp.md §2](../docs/architecture/cloud/gcp.md#2-zones-are-not-zones).

## Cross-schema invariants

These are asserted by a test, because three schemas agreeing by hand is a coincidence waiting to
end:

| Invariant | Where |
|---|---|
| `error_code` enums are byte-identical | `stage-result` ↔ `run-result` |
| The `stage` enum is identical | `run-context.lifecycle.stage` ↔ `stage-result.stage` ↔ `run-result.stages[].stage` |
| `stages_completed` is the stage set minus the `""` all-stages sentinel | `run-context` |
| Stage-result statuses are a strict subset of run-result statuses | 8 values vs 15 |
| Every contract field is echoed into `run-context.identity` | 5 fields |
| `sba_instance_id` is in `metadata.labels.required` | AD-05 + AD-11 |
| `placement.external_ip` is `const: false` | gcp.md §6 |

## Status

Phase 2, first artifact: **complete.** The next Phase 2 artifacts are
`tests/fixtures/contracts/{valid,invalid}/` and the resolver itself. The contract these encode is
specified in [api/api-contract.md](../docs/api/api-contract.md).
