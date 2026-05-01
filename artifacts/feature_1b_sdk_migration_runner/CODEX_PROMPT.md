# Codex Prompt: Implement Feature 1B SDK Migration Runner

You are working in an Elixir SurrealDB SDK repository.

Implement Feature 1B: SDK Migration Runner Implementation using the files in this package as the starting point.

## Primary goal

Add migration runner support to the SDK so users can run local `.surql` files idempotently while tracking applied migrations in SurrealDB.

## Tasks

1. Copy the `lib/`, `priv/`, and `test/` files into the SDK repo.
2. Search for `CODEX_TODO` markers.
3. Replace placeholder query/use shims with the SDK's actual public client/query API.
4. Ensure `SurrealDB.Migrations.install_registry!/2` works.
5. Ensure `SurrealDB.Migrations.run!/2` works.
6. Add or update tests so `mix test` passes.
7. Keep this phase focused. Do not add a CLI or Mix task yet.

## Expected public API

```elixir
SurrealDB.Migrations.install_registry!(client)

SurrealDB.Migrations.run!(client,
  path: "priv/surrealdb_migrations/app",
  target_ns: "app_ns",
  target_db: "app_db",
  sdk_version: "0.1.0"
)
```

## Required behavior

- Scan `.surql` files sorted by filename.
- Ignore non-`.surql` files.
- Compute SHA-256 checksums.
- Preflight each migration against `sdk_migration`.
- Skip already-applied migrations with matching checksum.
- Reject checksum drift.
- Reject currently running migrations.
- Reject failed migrations unless `allow_failed_rerun?: true`.
- Mark migration as `running` before executing.
- Execute migration against the target namespace/database.
- Mark as `applied` on success.
- Mark as `failed` on error.
- Persist duration and error message.

## Definition of Done

- `mix format` passes.
- `mix test` passes.
- At least checksum and file loader tests are pure unit tests.
- Runner tests either use an existing SDK test client/mocking strategy or are tagged as integration tests.
- No unrelated SDK architecture changes.
