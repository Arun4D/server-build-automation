# Post-Build Domain Join Role - STUB

## Status: Phase 1 Stub (Not Implemented)

This role is a **placeholder** that defines the interface for domain joining provisioned VMs to Active Directory. The domain join tooling is not yet decided in Phase 1.

## Purpose

- Defines the variable interface for domain join operations
- Fails fast with a clear TODO list of decisions needed
- Can be invoked independently via `playbooks/post_build_domain_join.yml`

## Variable Interface

| Variable | Type | Required | Description |
|---|---|---|---|
| `sba_instance_id` | string | ✅ | Unique run identifier from provision step |
| `domain_controller` | string | ✅ | AD domain controller FQDN |
| `domain_realm` | string | ✅ | Kerberos realm (e.g., EXAMPLE.COM) |
| `domain_ou` | string | ✅ | OU path for computer object |
| `domain_join_user` | string | ✅ | Account with join permissions |
| `domain_join_password` | string | ✅ | Credential for join account (no_log) |
| `domain_join_operation` | string | ❌ | `join` \| `verify` \| `leave` (default: `join`) |

## TODO - Decisions Needed Before Implementation

- [ ] Domain controller FQDN / realm configuration source
- [ ] OU placement strategy (per environment? per app_tier? static?)
- [ ] Credentials source (AAP credential? Vault? CyberArk? ServiceNow?)
- [ ] OS support matrix:
    - RHEL 9: realm/sssd (preferred) or adcli
    - Ubuntu 22.04: realm/sssd or adcli
    - Windows 2022: PowerShell Add-Computer
- [ ] Idempotent re-join logic (detect existing join, handle computer object cleanup)
- [ ] Verification method: realm list / klist / AD computer object exists
- [ ] Computer object naming convention (matches sba_name?)
- [ ] GPO link strategy
- [ ] Reboot handling after join
- [ ] Offline domain join support (djoin.exe for Windows)

## Future Implementation

When implemented, this role should:
1. Detect OS family and use appropriate tool (realm/sssd for Linux, PowerShell for Windows)
2. Join domain with specified OU placement
3. Verify join with `realm list` / `klist` / AD object check
4. Handle reboot if required
5. Clean up stale computer objects on re-join
6. Support `verify` and `leave` operations

## Provider Contract Reference

- `docs/architecture/provider-abstraction.md` — Role contract
- `docs/open-questions.md` — Open questions tracking