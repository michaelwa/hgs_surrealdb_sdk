# Feature 1B Handoff: SDK Migration Runner Implementation

## Context

Feature 1A created the SurrealDB schema artifact for a migration registry table named `sdk_migration`.

Feature 1B adds the Elixir SDK runtime code that uses that registry to apply `.surql` migration files safely.

## Scope

Implement migration runner support inside the SDK.

### In scope

- Migration file discovery
- SHA-256 checksum generation
- Registry bootstrap/install
- Idempotent preflight checks
- Checksum drift detection
- Running/applied/failed status updates
- Duration tracking
- Error message persistence
- Namespace/database targeting
- Unit tests for pure logic
- Integration test hooks for actual SurrealDB calls

### Out of scope

- Full CLI interface
- Mix task wrapper
- Rollbacks/down migrations
- Distributed locking beyond unique-index protection
- Migration dependency graph

These can be later phases.

## Public API target

```elixir
SurrealDB.Migrations.install_registry!(client)

SurrealDB.Migrations.run!(client,
  path: "priv/surrealdb_migrations/app",
  target_ns: "app_ns",
  target_db: "app_db",
  sdk_version: "0.1.0"
)
```

## Definition of Done

- `mix test` passes.
- SDK can scan `.surql` files from a directory.
- SDK ignores non-`.surql` files.
- SDK computes deterministic SHA-256 checksums.
- SDK skips migrations that are already `applied` with matching checksum.
- SDK errors on checksum drift.
- SDK errors on `running` migration conflicts.
- SDK blocks rerunning failed migrations unless `allow_failed_rerun?: true`.
- SDK marks rows as `running` before execution.
- SDK marks rows as `applied` after success.
- SDK marks rows as `failed` after execution error.
- SDK records `duration_ms`.
- SDK supports `target_ns` and `target_db` per run.

## Recommended future phases

- Feature 1C: Add Mix task wrapper.
- Feature 1D: Add integration tests with a real SurrealDB container.
- Feature 1E: Add migration generation helpers.
- Feature 1F: Add optional advisory lock table.
