# Tests

```
tests/
├── unit/          pure: resolver, naming, TagMapper, image, policy, state
├── integration/   playbook-level, mocked cloud APIs
├── e2e/           ServiceNow → engine → cloud → CMDB
├── molecule/      per-role scenarios, in a container EE
├── fixtures/      golden resolution files, contract corpus, tag matrix
└── security/      gitleaks, semgrep, and the architecture gates
```

## The rule everything else follows

> A behaviour is implemented in a pure function if it can be, and the function is tested
> exhaustively. Behaviour that cannot be pure is tested at the narrowest possible boundary, with
> the cloud mocked and everything above it real.

The second half is the part that gets forgotten. A test that mocks the resolver, the naming engine
and the tag mapper, and then asserts that a playbook calls `azure_rm_virtualmachine`, proves almost
nothing — `--syntax-check` proves the same thing.

**Mock what you call. Do not mock what you compute.**

## The layering

| Layer | Runs in | On every PR? | Gate |
|---|---|:--:|---|
| L1 pure unit | seconds, no containers | yes | yes |
| L2 contract | seconds | yes | yes |
| L3 static | <1 min | yes | yes |
| L4 Molecule | 5-15 min, container EE | yes | yes |
| L5 integration | 10-20 min, container EE | yes | yes |
| L6 sandbox cloud | 30-60 min, real cloud | merge to `main`, nightly | no |
| L7 E2E | 60-90 min, full stack | nightly, pre-release | no |
| L8 non-functional | varies | nightly, per release | no |

L6-L8 are deliberately not merge gates. Requiring a 60-minute wait for a PR produces batching and
rubber-stamping, which is worse than the coverage you would gain.

## The three tests that protect the architecture

Not the code — the *architecture*. These are the ones most often omitted:

| Test | Protects |
|---|---|
| **Canary leak test** — a synthetic value placed in every sink a secret would go, then searched for afterwards | `AD-15` |
| **Cross-engine parity** — the same contract on GitHub Actions and AAP must produce byte-identical `context.json` | `AD-01`, `AD-21` |
| **Chaos idempotence** — kill the process at each critical point; the assertion is always that exactly one resource carries the `sba_instance_id` | `AD-05` |

A happy-path-only suite passes an implementation that creates three servers when one was asked for.

## Fixtures are golden files, and a golden diff is a review artefact

`tests/fixtures/golden/*.json` is regenerated on every configuration change, and the diff is what
the reviewer reads. The same file is the resolver's regression suite. One artefact, two jobs.

`tests/fixtures/contracts/injection/` should grow continuously: `$(...)`, backticks, `${jinja}`,
newlines, CRLF, a null byte, a megabyte-long string. A resolver or template that passes `$(...)`
through to a shell is remote code execution, and that corpus is the only automated defence.

## Status

Phase 1: structure only. See
[testing-strategy.md](../docs/testing/testing-strategy.md).
