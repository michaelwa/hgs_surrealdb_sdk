# Feature 1: Migration Runner Registry Design

## Purpose

The Elixir SurrealDB SDK should be able to run `.surql` migration files safely and idempotently.

The SDK needs a small registry table that records which migration files were applied, against which target namespace/database, with which checksum, and with what result.

## Registry ownership

The registry is SDK-owned metadata. It should not live in application domain tables.

Recommended default location:

| Setting | Value |
|---|---|
| Registry namespace | `sdk_meta` |
| Registry database | `migration_registry` |
| Registry table | `sdk_migration` |

The registry records the target namespace/database on every row, allowing one registry to track multiple target databases.

## Data model

Each migration record should include:

| Field | Purpose |
|---|---|
| `migration_key` | Deterministic SDK-generated key for lookup/debugging |
| `target_ns` | Target namespace where migration applies |
| `target_db` | Target database where migration applies |
| `filename` | Migration file name, e.g. `202605010001_create_users.surql` |
| `checksum` | `sha256:` checksum of file contents |
| `sdk_version` | SDK version that attempted/applied migration |
| `status` | `pending`, `running`, `applied`, or `failed` |
| `started_at` | Attempt start timestamp |
| `finished_at` | Attempt finish timestamp |
| `applied_at` | Successful application timestamp |
| `duration_ms` | Runtime duration in milliseconds |
| `error_message` | Failure message, if any |
| `attempt_count` | Number of attempts for this migration row |
| `created_at` | Record creation timestamp |
| `updated_at` | Record update timestamp |

## Status lifecycle

```text
no row -> running -> applied
no row -> running -> failed
failed -> running -> applied    only when allow_failed_rerun?: true
failed -> running -> failed     only when allow_failed_rerun?: true
```

`pending` is included as an allowed status for future compatibility, but Feature 1 does not need to create pending rows.

## Idempotency behavior

The SDK should skip an already-applied migration only when both conditions are true:

1. same `target_ns`, `target_db`, and `filename`
2. same `checksum`

If the filename matches but checksum differs, reject as checksum drift.

## Rerun protection

The schema has a unique index on:

```text
target_ns, target_db, filename
```

This prevents duplicate registry rows for the same migration file in the same target database.

## Failed rerun behavior

A failed migration should not be retried by default.

If caller passes:

```elixir
allow_failed_rerun?: true
```

then the SDK may retry a failed migration, but it must update the existing failed row back to `running`. It must not insert a duplicate row.

On rerun, increment `attempt_count` and clear previous failure fields.

## Registry versus target clients

The runner has two database contexts:

| Operation | Namespace/database |
|---|---|
| registry install | registry namespace/database |
| registry preflight | registry namespace/database |
| mark running/applied/failed | registry namespace/database |
| execute migration SQL | target namespace/database |

For HTTP clients, this likely means cloning/updating the existing client struct's namespace/database fields.

For WebSocket clients, this feature should return an unsupported error unless the repo already has a safe reconnect/use strategy.

## Out of scope

Feature 1 intentionally excludes:

- rollback/down migrations
- dependency graph
- distributed locking
- CLI
- Mix task
- automatic migration generation
- WebSocket migration execution
