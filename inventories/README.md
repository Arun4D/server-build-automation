# Inventories

```
inventories/
├── dev/     group_vars/all/
├── nonprod/ group_vars/all/
└── prod/    group_vars/all/
```

**These contain control-plane hosts only** — the runner, the AAP controller, and the platform's own
servers.

**Not** the servers being built.

## Why the servers are not here

The obvious static inventory would list every server:

```yaml
# NOT THIS. And it is not only a maintenance burden.
all:
  hosts:
    pypa001:
    pypa002:
```

A server does not exist when the inventory is written. It exists because a request was made, and
the inventory would have to be updated after every build — by the automation, which means the
inventory is a *derived* artefact pretending to be a source of truth, and it drifts the moment a
build fails partway.

So the run inventory is **generated** from the run context and merged with the static one:

```
  static control_plane (from here, versioned)
        +
  generated run_group  (from run_context.json, per run)
        =
  the effective inventory
```

The run group is derived from the resolved configuration, so the hosts, the names, the
`ansible_host`, and the `sba_instance_id` are exactly the resolved values. An operator can inspect
the generated file, and it is written to the run state, so the inventory a build actually used is
recoverable after the fact.

This is [AD-18](../docs/architecture/architectural-decisions.md#ad-18-inventories-hold-control-plane-hosts-only).

## `group_vars/all/`

Environment-scoped variables for the **platform's own** behaviour, not for the servers:

| Variable | Purpose |
|---|---|
| `sba_environment` | `dev` / `nonprod` / `prod` |
| `sba_engine_routing` | Which engine runs this environment |
| `sba_config_path` | The configuration tree for this environment |
| `sba_run_state_prefix` | The run-state object-store prefix |
| `sba_servicenow_instance` | The ServiceNow instance to call back |
| `sba_policy_file` | The policy floor for this environment |
| `sba_batch_serial` | The serial batch size |

**No credentials.** None. A credential in an inventory variable is a credential in Git, in every
artifact that captures variables, and in every log that prints them.

## `prod` is a different repository

Production inventories should be a separate repository, pulled at run time by a narrow identity.
Keeping `inventories/prod/` in this repository means a production hostname is visible to anyone with
read access to the source, which is a much larger group than the people who should know it. This is
recorded as a hardening item in
[roadmap.md §9 ](../docs/roadmap.md#9-phase-8--production-hardening).

## Status

Phase 1: structure only. See
[repository-structure.md](../docs/architecture/repository-structure.md#1-layout).
