# Execution Environment

```
execution-environment/
├── requirements.txt                 the design's intended versions (Phase 1)
├── requirements-constraints.txt     version ceilings and why each exists
└── build.sh / verify.sh             Phase 4
```

Plus `execution-environment.yml` at the repository root.

## What it is for

GitHub Actions and AAP run the same playbooks. An EE makes them run them **identically**: the same
Ansible, the same collections, the same Python packages, the same OS libraries.

Without it, "it works on GitHub Actions and fails on AAP" is a normal and maddening class of bug,
and it is almost always a version difference in a transitive dependency.

## Promoted by digest, never rebuilt

```
  commit ──▶ ansible-builder build ──▶ sba-ee@sha256:abc123...
                                              │
                    ┌─────────────────────────┼─────────────────────────┐
                    ▼                         ▼                         ▼
                  dev                     nonprod                    prod
             (a moving tag)            (the digest)             (THE SAME digest)
```

**The same digest runs nonprod and prod.** Not a rebuilt one, not a retagged one. If nonprod and
prod run different EEs, then nonprod has not tested what prod runs, and the whole promotion model
is theatre.

| Environment | Reference | Why |
|---|---|---|
| dev | A moving tag | Fast iteration matters more than reproducibility here |
| nonprod | The digest | This is the artifact that gets tested |
| prod | **The same digest** | Non-rebuild is the entire point |

## Reproducibility

An EE built from floating versions is not reproducible, and a non-reproducible EE is a
non-reproducible production build — where "which code built this server" has no answer.

So: exact pins in `requirements.yml`, exact pins with hashes in
`requirements.txt`, and a `requirements-constraints.txt` carrying upper bounds where a major release
would change behaviour silently.

**The ceilings exist because the failure mode is a wrong value, not a crash.** A cloud SDK major
release that changes a response shape does not raise; it returns a different field, and the
platform writes that field into a production resource. A Jinja2 major release that renders a
template differently does not raise either — and a template that renders differently between
environments is precisely what this whole design exists to prevent.

`cryptography<43.0.0` is in the constraints file for a concrete reason: 43 removed APIs the Azure
and AWS SDKs still call. Pinning it means the EE build fails with a clear message, and a human
resolves the incompatibility — rather than the incompatibility surfacing as an `ImportError` in the
middle of a production build.

## The EE test that matters

Molecule **run inside the built EE**, not on the host. It is the only test that proves the EE is
actually complete: a role that passes on a developer machine with every collection installed, and
fails because the EE is missing one, is a role that will fail in production.

## Status

Phase 1: structure only, and the version pins are the design's intent rather than a resolved lock.
The hash-pinned lock is produced in Phase 4. See
[execution-environment.md](../docs/architecture/execution-environment.md).
