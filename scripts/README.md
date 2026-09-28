# Scripts

```
scripts/
├── resolve_configuration.py    The CLI. Thin. Delegates to lib/sba_resolver.
├── sba_state                   The run-state client
├── verify_tags                 The tag-integrity auditor
└── lib/
    └── sba_resolver/           The pure resolver package
```

## `lib/sba_resolver` is pure

No Ansible dependency. No cloud SDK. **No I/O outside reading the configuration tree.** No clock.
No randomness.

That is [AD-22](../docs/architecture/architectural-decisions.md#ad-22-resolver-is-read-only-and-side-effect-free),
and it is not tidiness — it is what makes three things possible:

| Consequence | Why purity enables it |
|---|---|
| 100% branch coverage | A few hundred lines of pure Python. Every branch is a decision someone could get wrong, and none can be discovered by running it |
| Byte-identical output on both engines | GitHub Actions and AAP call the same code, so their `context.json` must be identical. That is the automated form of cross-engine parity |
| Order-independence provable | Two different key orderings in the config resolve identically, so idempotency's `CONFIGURATION_DRIFT_IN_RUN` check does not fire on a no-op re-run for no reason |

If the resolver ever needed the current time, a random value, or a cloud API call, one of those
three properties would be gone.

## The CLI is thin

```python
#!/usr/bin/env python3
"""Resolve a business contract into a run context. See AD-22."""
import argparse, json, sys
from lib.sba_resolver import resolve, ResolutionError
from lib.sba_resolver.errors import error_payload

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--request", required=True, help="business request JSON")
    parser.add_argument("--config", default="configuration")
    parser.add_argument("--out", help="write run_context.json here; default stdout")
    parser.add_argument("--env", required=True, help="dev | nonprod | prod")
    args = parser.parse_args()

    try:
        context = resolve(load(args.config), load_request(args.request), environment=args.env)
    except ResolutionError as exc:
        json.dump(error_payload(exc), sys.stderr, indent=2)
        return 2

    payload = json.dumps(context, indent=2, sort_keys=True)
    if args.out:
        with open(args.out, "w") as fh:
            fh.write(payload + "\n")
    else:
        print(payload)
    return 0

if __name__ == "__main__":
    sys.exit(main())
```

Two details that are load-bearing: `sort_keys=True`, so the output is byte-stable, and exit code
`2` on a resolution failure, so the caller can distinguish "the request is wrong" from "the
platform is broken" without parsing anything.

## `verify_tags`

The daily orphan sweep. For every resource in the managed subscriptions, classify it:

| Class | Cause | Action |
|---|---|---|
| `ORPHAN_UNTRACKED` | No `sba_instance_id` tag. Something created infrastructure without the ownership rule | **Investigate. Paged.** This means the estate holds resources the platform cannot reason about |
| `ORPHAN_STALE` | The tag is valid but the run state is gone | Reconcile |
| `ORPHAN_INTERRUPTED` | A crash left a resource behind | Compensate that run; the tag makes the target unambiguous |

`ORPHAN_UNTRACKED` is paged and the other two are digest items, deliberately. The first indicates
the tag-with-create rule has been violated somewhere, and it is the condition under which
create-or-adopt cannot be trusted.

## Status

Phase 1: structure only. The resolver arrives in Phase 2 and is the first thing written. See
[roadmap.md §3 ](../docs/roadmap.md#3-phase-2--resolver-and-contract).
