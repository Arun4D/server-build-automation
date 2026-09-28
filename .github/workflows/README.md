# Workflows

**This is the canonical location for the runtime workflows, and it is not configurable**
([AD-12](../../docs/architecture/architectural-decisions.md#ad-12-canonical-workflows-live-in-githubworkflows)).

GitHub only recognises workflow files in `.github/workflows/`. A runtime workflow placed in
`automation/github/workflows/` is a file that looks valid, passes every YAML linter, and never runs.
That is the entire reason this rule exists.

## Two pipelines, one directory

| | **Runtime** | **CI/CD** |
|---|---|---|
| Files | `server-build.yml`, `server-destroy.yml`, `server-validate.yml`, `post-build.yml` | `ci-lint.yml`, `molecule.yml`, `integration.yml`, `sec-scan.yml`, `ee-build.yml` |
| Trigger | ServiceNow's adapter, or an operator | `pull_request`, `push` to a protected branch, `schedule` |
| Purpose | Execute a server build | Quality, security, EE build, promotion |
| Credentials | Job-scoped OIDC for the target environment | CI identity. **Never** a production cloud identity |

**The separation rule:** a runtime workflow may never run with a CI identity, and a CI workflow may
never hold a production cloud identity.

The two failure modes this prevents, and they are the ones that actually happen:

- A `pull_request` workflow holding a production cloud identity turns a fork pull request into
  production access. The OIDC trust policy pins the ref, so it is denied — but only if the
  separation is designed, not assumed.
- A runtime workflow with CI credentials means a build failure is investigated with the wrong
  permissions, and a compromised CI runner can provision production.

## Branch protection

A runtime workflow must exist on the **default branch** before `workflow_dispatch` can trigger it.
Every runtime workflow is therefore protected by the same branch rules as the code, with
CODEOWNERS review on `.github/workflows/`.

## Required workflow controls

| Control | Reason |
|---|---|
| `permissions: contents: read` by default | Least privilege. Never `write-all` |
| Every action pinned by SHA, not by tag | A tag is mutable, and a supply-chain attack does not need a vulnerability |
| `concurrency` per `correlation_id` | Prevents two dispatches of one request running at once |
| `no_log: true` on every credential-consuming step | A step that prints a token has leaked it |
| No secret in `env`, `with`, or the dispatch payload | `AD-15` |
| `timeout-minutes` set on every job | An unbounded job holds a runner and a slot |
| Environment protection for the `prod` environment | Approvals and scoped secrets |

## Status

Phase 1: structure only. Workflows arrive in Phase 4. See
[repository-structure.md §9 ](../../docs/architecture/repository-structure.md#9-github) and
[cicd-pipeline.md §1 ](../../docs/architecture/cicd-pipeline.md#1-two-pipelines-one-repository).
