# Post-Build Agent Install Role - STUB

## Status: Phase 1 Stub (Not Implemented)

This role is a **placeholder** that defines the interface for installing monitoring/security agents on provisioned VMs. The agent choice is not yet decided in Phase 1.

## Purpose

- Defines the variable interface for agent install operations
- Fails fast with a clear TODO list of decisions needed
- Can be invoked independently via `playbooks/post_build_agent_install.yml`

## Variable Interface

| Variable | Type | Required | Description |
|---|---|---|---|
| `sba_instance_id` | string | ✅ | Unique run identifier from provision step |
| `agent_type` | string | ✅ | `dynatrace` \| `datadog` \| `crowdstrike` \| `other` |
| `agent_install_method` | string | ✅ | `package` \| `script` \| `container` |
| `agent_config` | dict | ✅ | Agent-specific configuration (tenant, API key, policy, etc.) |
| `agent_install_operation` | string | ❌ | `install` \| `verify` \| `uninstall` \| `upgrade` (default: `install`) |

## TODO - Decisions Needed Before Implementation

- [ ] Agent selection: Dynatrace vs Datadog vs CrowdStrike vs other
- [ ] Installation method: package (rpm/deb/msi) vs script vs container
- [ ] Configuration source: AAP survey? Vault? Parameter store? ServiceNow?
- [ ] Policy/tenant assignment per environment
- [ ] Connectivity verification (heartbeat, test metric, first scan)
- [ ] Upgrade/rotation strategy
- [ ] OS support matrix per agent
- [ ] Proxy/firewall considerations
- [ ] Agent uninstall/cleanup procedure
- [ ] Compliance reporting integration

## Future Implementation

When implemented, this role should:
1. Install agent based on `agent_type` and `agent_install_method`
2. Configure agent with `agent_config` parameters
3. Verify connectivity (heartbeat, test metric, first scan)
4. Support `verify`, `uninstall`, and `upgrade` operations
5. Handle OS-specific installation paths

## Provider Contract Reference

- `docs/architecture/provider-abstraction.md` — Role contract
- `docs/open-questions.md` — Open questions tracking