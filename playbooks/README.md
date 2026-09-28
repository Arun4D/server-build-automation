# Playbooks

```
playbooks/
├── server_build.yml        THE entry point. Stage-parameterised.
├── server_destroy.yml      Governed teardown. Requires an approved request.
├── server_validate.yml     Pre-flight only. Creates nothing.
├── post_build.yml          One stage, re-runnable against a live server.
├── stages/                 The 11 stage wrappers
├── infrastructure/         Provider-specific stage playbooks
├── os/                     OS-specific stage playbooks
└── post_build/             Post-build stage playbooks
```

## One entry point

```yaml
# playbooks/server_build.yml
- name: Server build
  hosts: "{{ target_group | default('control_plane') }}"
  gather_facts: false
  tasks:
    - name: Wait for the run-state lock
      ansible.builtin.include_role: { name: sba.platform.run_state }

    - name: Execute the requested stage, or the whole pipeline
      ansible.builtin.include_tasks:
        file: "stages/{{ sba_stage | default('all') }}.yml"
```

Every invocation is the same playbook with a different stage. `sba_stage: all` runs the pipeline;
`sba_stage: domain_join` runs one stage against a completed predecessor. There is no
`server_post_build_join.yml`, and that absence is the design
([AD-01](../docs/architecture/architectural-decisions.md#ad-01-single-entry-playbooks--staged-re-entry)).

**The reason.** A second entry playbook for post-build work is a second place for the stage order
to be wrong, and the stage order is what determines whether a server ends up with DNS records for a
host that failed to join the domain. One playbook, one stage list, one place to be correct.

The mechanism that makes it work is durable state: each stage records its completion and its
observed resources, so a later invocation knows what already exists without re-deriving it.

## Stage wrappers

One file per stage. A wrapper:

1. Acquires the per-stage, per-instance lock (CAS)
2. Reads the run state
3. Invokes the role
4. Runs the **stage assertion** — a real check, not a hard-coded success
5. Records the attempt, the observed resources, and the result
6. Releases the lock
7. Releases the resource on failure, per the compensation rules

The wrapper never contains logic of its own. Orchestration lives here; implementation lives in
roles. A wrapper that starts making decisions about infrastructure has become a role that is hard to
test.

## `server_destroy.yml` is a separate playbook, deliberately

Teardown is a governed act, not a consequence of a failed build
([AD-16](../docs/architecture/architectural-decisions.md#ad-16-forward-fix-over-auto-destroy)). A
build that failed at Stage 6 and took the server with it would also take the DNS record and the
CMDB relationship into an inconsistent state, and would destroy the evidence needed to diagnose the
failure.

So destroy is a separate playbook, a separate workflow, a separate ServiceNow request, and a
separate identity — `svc-sba-destroy` — which is denied write access to shared networking.

## Status

Phase 1: structure only. See
[request-lifecycle.md](../docs/architecture/request-lifecycle.md) and
[repository-structure.md](../docs/architecture/repository-structure.md).
