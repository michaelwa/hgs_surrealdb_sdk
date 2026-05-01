# Feature 1B: SDK Migration Runner Implementation

This package is a Codex-ready handoff for extending the Elixir SurrealDB SDK with a migration runner that uses the Feature 1A registry schema.

## Goal

Add SDK runtime support for applying `.surql` migration files safely and idempotently.

The runner should:

- install/bootstrap the SDK registry schema
- discover local `.surql` files
- compute SHA-256 checksums
- check whether each migration already ran
- skip already-applied migrations with the same checksum
- reject checksum drift
- prevent reruns unless explicitly allowed
- mark migrations as `running`, `applied`, or `failed`
- record `duration_ms`, `sdk_version`, and `error_message`
- support multiple target namespaces/databases

## Suggested public API

```elixir
SurrealDB.Migrations.install_registry!(client)

SurrealDB.Migrations.run!(
  client,
  path: "priv/surrealdb_migrations/app",
  target_ns: "app_ns",
  target_db: "app_db",
  sdk_version: "0.1.0"
)
```

Non-bang variants should return tagged tuples:

```elixir
{:ok, results}
{:error, reason}
```

## Files

```text
lib/surrealdb/migrations.ex
lib/surrealdb/migration.ex
lib/surrealdb/migration/registry_entry.ex
lib/surrealdb/migration/checksum.ex
lib/surrealdb/migration/file_loader.ex
lib/surrealdb/migration/registry.ex
lib/surrealdb/migration/runner.ex
priv/surrealdb_migrations/sdk_registry/001_define_migration_registry.surql
test/surrealdb/migration/checksum_test.exs
test/surrealdb/migration/file_loader_test.exs
test/surrealdb/migration/runner_test.exs
docs/feature_1b_handoff.md
```

## Codex implementation notes

The included Elixir code is intentionally written as implementation scaffolding. Codex should adapt calls to the actual SDK query API.

Search for these markers:

```text
CODEX_TODO
```

Those are integration points where the existing SDK client/query functions need to be wired in.
