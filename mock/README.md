# Mock Service

```
mock/
├── run.sh
├── requirements.txt
├── servicenow/       a Table API subset + a Business Rule analogue
├── state_store/      a local run-state store
└── cloud/            optional; recorded fixtures are usually better
```

Used by the L5 integration tests and by a developer's local run of the whole pipeline.

## Fidelity is the whole point

A mock that returns a generic `200` for everything passes tests that a real cloud would fail. These
mocks must reproduce the **specific pathologies the design defends against**:

| Behaviour the platform depends on | The mock must reproduce |
|---|---|
| Tag-propagation eventual consistency | The first filtered read returns empty. The second returns the instance |
| Ambiguous delete | `NotFound` on a second delete of the same resource |
| Rate limiting | `429` for the first N calls, then success |
| Slow provisioning | `pending` for M polls, then `running` |
| Immutable attribute rejection | `409` on a zone or region change |
| Quota | `QuotaExceeded` for a specific size and region combination |
| Asynchronous deletion | `200` on delete, while the resource still appears in reads |
| Lost response | A create that succeeds, and then a timeout |

That first row is the one to insist on. A mock that returns the instance on the first read would let
an implementation that creates on a stale read pass its tests — and that implementation duplicates
servers in production. The mock's job is to reproduce the pathology, not to make the code pass.

## The state-store mock must implement real CAS

Not last-write-wins. The entire locking and idempotency design is built on compare-and-swap:

```python
def cas_write(self, key, expected_version, value):
    current = self._read(key)
    if current is not None and current.version != expected_version:
        raise CasConflict(key, current.version)   # the caller re-reads and retries
    ...
```

A mock with last-write-wins would let a lock bug pass every test, because the race the lock exists
to prevent would simply not exist. This is the one mock that must be more faithful than convenient.

## Cloud emulator?

Not by default. A cloud emulator is a large dependency, and recorded fixtures plus a
pathology-reproducing mock cover the platform's actual dependency: **the behaviours above**, not
the full API surface.

## Status

Phase 1: structure only. See
[testing-strategy.md §6 -7](../docs/testing/testing-strategy.md#6-l4--molecule-role-tests).
