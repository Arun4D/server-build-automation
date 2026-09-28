# Configuration

The catalogue. **This directory is the platform's real decision surface**: the roles decide *how*
to build, and this directory decides *what*.

That is the reason for the structural decision in
[repository-structure.md §5 ](../docs/architecture/repository-structure.md#5-configuration): it is
split **by kind**, not by environment.

```
configuration/
├── clouds/          what a cloud supports
├── regions/         where it can be built
├── server_roles/    what a kind of server looks like
├── applications/    what an application needs
├── os/              which OS versions are allowed
├── images/          which images, pinned and expiring
├── environments/    what is different about dev / nonprod / prod
├── policies/        the floors and ceilings per environment
├── routing/         which engine runs which environment
├── tags/            the canonical key set, per provider
└── naming/          patterns, DNS scopes, reserved words
```

**Why not `configuration/dev/`, `configuration/nonprod/`, `configuration/prod/`?** Because that
triplicates the catalogue, and duplicated catalogues drift. Drift is not cosmetic here: it means dev
builds a server that production cannot, and the difference is discovered in production. Adding an
environment is one file in `environments/`, one in `policies/`, and one line in `routing/` — not a
catalogue copy.

**Adding an application is one file.** If it needs a code change, the model is wrong.

## Precedence

Lower to higher. Each layer may only override a key it explicitly declares.

```
1. defaults            the catalogue's own defaults
2. os/                 OS-family constraints
3. server_roles/       what this kind of server requires
4. applications/       this application's requirements
5. environments/       this environment's overrides
6. the request         the business request's explicit choices
7. policies/           the gate — a floor, not a value
```

Layers 1-6 produce the single effective configuration. Layer 7 does not merge; it accepts or
rejects. A policy can only make a resolved configuration *illegal*, never *different*, which is why
adding a policy can never silently change what a server looks like.

Full model: [configuration-resolution.md](../docs/architecture/configuration-resolution.md).

## Review discipline

Every change here regenerates the golden resolution files, and **the diff is the review artefact**:

```
  $ make golden
  tests/fixtures/golden/case_014.json | 4 ++--
  - "vm_size": "Standard_D4s_v6"
  + "vm_size": "Standard_D8s_v6"
```

Without this, a one-character change to a default would alter production infrastructure with no
visible diff. With it, every configuration change is self-documenting and reviewable on its own
terms — and it doubles as the regression test suite for the resolver.

## Secrets

None. Ever. No credential, token, key, or connection string belongs in this directory. Values come
from the credential store at the moment of use, with `no_log: true`. See
[secret-management.md](../docs/security/secret-management.md).

## Status

Phase 1: structure only. Files arrive in Phase 2. See
[roadmap.md §3 ](../docs/roadmap.md#3-phase-2--resolver-and-contract).
