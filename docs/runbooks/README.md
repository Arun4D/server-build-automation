# Runbooks

Operational procedures. **Written for someone who did not build the platform**, because that is
who will need them at 02:00.

Phase 1: structure only. The procedures are identified below and written in Phase 6, when there is
a working system to write them against. See
[roadmap.md §7 ](../roadmap.md#7-phase-6--post-build-integration).

## Planned runbooks

| Runbook | Trigger |
|---|---|
| `01-triage-partial-build.md` | A request reaches `Manual Attention` |
| `02-recover-failed-build.md` | A request reaches `Failed` |
| `03-re-run-a-stage.md` | A specific stage needs re-running after a fix |
| `04-destroy-server.md` | An approved teardown |
| `05-diagnose-policy-block.md` | A `Blocked by policy` rejection |
| `06-diagnose-name-collision.md` | A `NAME_TAKEN` escalation |
| `07-reconcile-drift.md` | A `DRIFT_*` report item |
| `08-investigate-orphan.md` | A non-zero orphan report. **Paged** |
| `09-rotate-credential.md` | A scheduled or emergency rotation |
| `10-state-store-outage.md` | The run-state store is unavailable |
| `11-ee-rollback.md` | A bad Execution Environment reaches production |
| `12-incident-ee-unavailable.md` | The EE cannot be pulled. **Blocks all production builds** |
| `13-region-outage.md` | A cloud region is degraded |
| `14-rebuild-after-drift.md` | A server must be rebuilt rather than repaired |

## The rule for every runbook

Each one answers the same six questions, in this order:

1. **What does this look like?** The exact alert, status, or error code
2. **Is it safe to act?** What must be confirmed before touching anything
3. **What is the impact?** What a wrong action costs
4. **What do I do?** Numbered, copy-pasteable
5. **How do I know it worked?** The observable that changed
6. **What if that did not work?** The escalation path

A runbook that reaches step 4 and stops is a note, not a runbook. Step 6 is the one that matters
most at 02:00, because it is the question actually being asked.

## Principles these runbooks will encode

| Principle | Why |
|---|---|
| Never destroy to fix a failure | Forward-fix. `AD-16` |
| Never delete a resource without the `sba_instance_id` tag | It may not be the platform's |
| Never re-raise a request to retry a stage | Use stage re-run, or the duplicate will create a second server |
| Never edit a resolved value in the catalogue to make one build work | That is how a special case becomes permanent |
| Never bypass a policy to unblock a build | A policy that is routinely bypassed is not a control |
| Prefer re-running one stage over re-running the build | Cheaper, and it preserves the diagnostic evidence |
