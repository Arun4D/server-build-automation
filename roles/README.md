# Roles

Grouped **by the resource they act on**, not alphabetically. The grouping is the dependency graph,
so the stage order is visible in the directory structure.

```
roles/
├── platform/     the run itself. No infrastructure.
├── cloud/        the compute instance
├── image/        the image reference
├── os/           the guest OS
├── domain/       the AD computer object
├── dns/          the DNS record set
├── cmdb/         the ServiceNow CI record
├── security/     the guest's security posture
├── monitoring/   the guest's monitoring
└── backup/       the guest's backup
```

## The three rules

1. **A cloud module may be called only in `cloud/` or `image/`.** Enforced by a CI gate. This is
   what makes risk `R-08` checkable rather than aspirational.
2. **A role depends only on `platform/` and on other `platform/` roles.** A role never includes a
   domain role, so the DAG stays acyclic and no cycle is possible.
3. **Every role is self-contained**: `tasks/`, `defaults/`, `vars/`, `handlers/`, `meta/`, `tests/`.
   A role reaching outside its own directory is a coupling that will be invisible later.

## Stage ↔ role mapping

| Stage | Roles |
|---|---|
| 1 `validate` | `platform/validate_request`, `platform/resolve_configuration` |
| 2 `bootstrap` | `platform/naming`, `platform/image_resolver` |
| 3 `provision` | `cloud/<provider>_vm`, `image/<provider>_image` |
| 4 `os_config` | `os/<os>_baseline`, `security/cis_*`, `security/*_agent`, `monitoring/*`, `backup/*` |
| 5 `validate_os` | `platform/validate_request` (assertion mode) |
| 6 `domain_join` | `domain/<os>_domain_join` |
| 7 `install_agents` | `security/*_agent`, `monitoring/*`, `backup/*` |
| 8 `enroll_agents` | as above |
| 9 `dns` | `dns/dns_registration` |
| 10 `cmdb` | `cmdb/servicenow_cmdb` |
| 11 `post_build` | one role, re-runnable in isolation |

## Role contract

The three provider roles in `cloud/` implement **the same six task groups with the same task names,
the same parameters, and the same defaults**: `preflight`, `lookup_instance`, `verify_immutable`,
`resolve_image`, `create_instance`, `attach_networking`, `attach_storage`, `record_observed`,
`converge_instance`, `wait_for_ready`, `list_owned_resources`, `delete_instance`,
`assert_instance`.

Dispatch is a **static** enum. No user-controlled role name, ever — that is `AD-08`, and it is
the reason the contract is a role convention rather than a plugin API. The reasoning, and why a
Python base class would be the wrong answer, is in
[provider-abstraction.md §1 ](../docs/architecture/provider-abstraction.md#1-why-a-contract-not-a-base-class).

## Every role must

- Pass its **idempotence** Molecule scenario: a second converge reports `changed == 0`
- Have a `README.md`: what it does, what it requires, what it **never** does
- Put no secret in `defaults/`, `vars/`, or any task argument
- Return structured data, not print to stdout
- Set `no_log: true` on every task that consumes a credential
- Use `fully qualified collection names` throughout

## Status

Phase 1: structure only. Roles arrive in Phases 4-6. See
[roadmap.md](../docs/roadmap.md) and
[role-dependency-model.md](../docs/architecture/role-dependency-model.md).
