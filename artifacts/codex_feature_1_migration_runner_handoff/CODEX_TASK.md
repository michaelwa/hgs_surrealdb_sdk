# Codex Task: Feature 1 — SurrealDB Migration Runner Registry

## Goal

Implement SDK support for running `.surql` migrations with a SurrealDB-backed registry table named `sdk_migration`.

This feature has two parts:

1. A registry schema that records migration attempts and protects against unsafe reruns.
2. An Elixir SDK migration runner that installs the registry, scans `.surql` files, checks migration state, runs pending migrations, and records outcomes.

## Critical instruction

Inspect the current repository before coding.

Do not copy paths or APIs from this handoff blindly. Treat this handoff as the feature behavior/specification. The repository is the source of truth for:

- file path conventions
- OTP application name
- public module namespace
- public query API
- client struct fields
- query result shape
- error shape
- HTTP/WebSocket behavior
- test/mocking strategy

Do not invent APIs that do not exist in the repo.

## Known repo constraints from prior review

These were previously observed and should be verified before coding:

- Repo paths use `lib/surreal_db.ex` and `lib/surreal_db/...` conventions.
- Public modules are named `SurrealDB.*`.
- Existing public query API is likely:
  - `SurrealDB.query(client, query)`
  - `SurrealDB.query(client, query, variables)`
- Query responses are likely shaped like:

```elixir
{:ok, %SurrealDB.QueryResult{results: results, statuses: statuses, raw: raw}}
{:error, %SurrealDB.Error{} = error}
```

- `%SurrealDB.Client{}` likely has `namespace` and `database` fields.
- There is no public `SurrealDB.use/3` API.
- HTTP requests likely use `client.namespace` and `client.database` as SurrealDB namespace/database headers.
- WebSocket connections likely issue RPC `use` during connection setup. Changing namespace/database on an already-connected websocket client may not be safe.

Verify all of this before implementation.

## Public API to implement

Expose non-bang and bang variants:

```elixir
SurrealDB.Migrations.install_registry(client, opts \\ [])
SurrealDB.Migrations.install_registry!(client, opts \\ [])

SurrealDB.Migrations.run(client, opts)
SurrealDB.Migrations.run!(client, opts)
```

Expected usage:

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

Non-bang returns:

```elixir
install_registry(client, opts) :: :ok | {:error, reason}
run(client, opts) :: {:ok, results} | {:error, reason}
```

Bang variants should raise on error using the repo's existing error conventions where possible.

## Registry location

Default registry namespace/database:

```elixir
registry_ns: "sdk_meta"
registry_db: "migration_registry"
```

The registry table is always:

```text
sdk_migration
```

Registry operations should use a registry-scoped client.

Actual migration SQL execution should use a target-scoped client.

For HTTP clients, this probably means deriving/cloning the existing `%SurrealDB.Client{}` with updated `namespace` and `database` fields.

Do not depend on `SurrealDB.use/3`; it does not exist.

## WebSocket scope

Feature 1 supports HTTP clients only unless the repository already has a safe reconnect/use strategy.

If the runner receives a connected WebSocket client and safe namespace/database switching is not implemented, return a structured error such as:

```elixir
{:error, {:unsupported_client_for_migrations, :websocket}}
```

Do not attempt unsafe namespace/database mutation for connected WebSocket clients in this feature.

## Migration file behavior

- Scan only `.surql` files.
- Ignore non-`.surql` files.
- Sort migrations lexicographically by filename.
- Read file contents.
- Compute deterministic SHA-256 checksum with `"sha256:"` prefix.
- Use filename and checksum for registry checks.

Checksum example:

```elixir
hash = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
"sha256:" <> hash
```

## Registry preflight rules

For each migration file, query `sdk_migration` by `target_ns`, `target_db`, and `filename`.

Rules:

| Registry state | SDK behavior |
|---|---|
| no row | run migration |
| `applied` + same checksum | skip |
| `applied` + different checksum | reject checksum drift |
| `running` | reject; migration already running |
| `failed` | reject unless `allow_failed_rerun?: true` |

Important correction:

When `allow_failed_rerun?: true`, do not insert a new row. The registry has a unique index on `target_ns`, `target_db`, and `filename`. Update the existing failed row back to `running`, increment `attempt_count`, update `sdk_version`, and clear previous error fields.

## Execution flow

For each pending migration:

1. Preflight registry state.
2. Mark row as `running` before executing migration SQL.
3. Execute migration SQL against `target_ns` / `target_db`, not the registry database.
4. On success, mark row as `applied`.
5. On failure, mark row as `failed`.

Record:

- `started_at`
- `finished_at`
- `applied_at`
- `duration_ms`
- `error_message`
- `sdk_version`
- `attempt_count`
- `updated_at`

## install_registry behavior

Install the registry schema from:

```text
priv/surrealdb_migrations/sdk_registry/001_define_migration_registry.surql
```

Load this robustly. Prefer:

```elixir
:code.priv_dir(:hgs_surrealdb_sdk)
```

with a development/test fallback to repo-local:

```text
priv/surrealdb_migrations/sdk_registry/001_define_migration_registry.surql
```

If the actual OTP app name differs, use the repo's actual OTP app name.

## Query result handling

Registry helper functions must unwrap the repo's real query result type.

If the repo returns:

```elixir
{:ok, %SurrealDB.QueryResult{results: results}}
```

then implement a normalization helper for SELECT results because SurrealDB may return nested result sets depending on whether a query contains one statement or multiple statements.

Do not assume raw lists are returned directly from `SurrealDB.query/2` or `SurrealDB.query/3`.

## Do not add in Feature 1

Do not add:

- CLI
- Mix task
- rollback/down migrations
- dependency graph
- distributed locking
- websocket migration support unless already safe in repo

## Tests

Use the repository's existing test/mocking strategy. Add pure unit tests where possible.

Required tests:

- missing required options
- sorted `.surql` loading
- non-`.surql` files ignored
- checksum determinism
- registry install loads schema from `priv`
- applied migration skip with matching checksum
- checksum drift rejection
- running migration rejection
- failed migration rejection by default
- failed migration rerun updates existing row rather than inserting duplicate
- mark migration as failed after execution error
- registry operations use registry namespace/database
- migration execution uses target namespace/database

Full real SurrealDB tests should be tagged `:integration` and not required for normal `mix test`.

## Done when

- Implementation follows current repo conventions.
- No invented APIs.
- Registry schema is included under `priv/surrealdb_migrations/sdk_registry/`.
- Public API works as described.
- `mix format` passes.
- `mix test` passes.
