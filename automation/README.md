# Automation

Engine-specific objects, kept out of `.github/` and out of the Ansible project because neither is
a natural home for them.

```
automation/
├── github/       the adapter, composite actions, runner configuration
├── aap/          job templates, workflow templates, credential definitions, inventories
└── servicenow/   Business Rules, REST Messages, Flows, Transform Maps
```

## Why these are not elsewhere

| Object | Why not in `.github/workflows/` | Why not an Ansible project file |
|---|---|---|
| GitHub adapter | It is application code, not a workflow. A workflow in `automation/github/` also looks valid and never runs | It is not Ansible at all |
| AAP job templates | AAP is not GitHub | They are engine configuration, not Ansible. Exporting them mixes a declarative artefact with the code that consumes it |
| ServiceNow objects | Same | Same |

## `aap/credentials/` holds definitions, never values

A credential **definition** is safe to commit:

```yaml
- name: Azure - Production - OIDC
  credential_type: "Microsoft Azure"
  inputs:
    client_id: "..."            # not secret
    subscription_id: "..."      # not secret
    # No client_secret. The token is exchanged at run time.
  managed: true
```

A credential **value** is not, and never will be. The value is entered in the AAP UI or via the API
by the platform team, and the repository rule plus a pre-commit gitleaks hook enforce the
difference.

Keeping the definitions in version control has a real benefit: the **set** of credentials is
reviewable, so a credential nobody declared cannot be used, because the platform only reads what
the inventory of definitions contains.

## ServiceNow side

| Object | Purpose |
|---|---|
| Business Rule | Fires on the RITM state change, builds the payload, calls the adapter |
| REST Message | The outbound call to the adapter, with mTLS or a signed token |
| Flow | The requester's approval journey, and the state transitions |
| Transform Map | The `service_request` → CI correlation for the CMDB callback |
| Custom role | Enforces that only the correct group can approve a production request |

`requested_by` is **not** in the wire contract. ServiceNow derives it server-side and uses it for
the approval audit trail; putting it in the payload would make an unauthenticated field
security-relevant (`AD-19`).

## Status

Phase 1: structure only. See
[servicenow-github-actions.md](../docs/architecture/servicenow-github-actions.md) and
[servicenow-aap.md](../docs/architecture/servicenow-aap.md).
