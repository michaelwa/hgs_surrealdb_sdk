# Migration Registry Correctness and Recovery Policy Design

**Goal:** Make registry scope options effective for every migration operation and provide safe, explicit recovery for rows left `running` after a crash.

## Context

`SurrealDB.Migrations` currently accepts options but queries the registry through the target client scope. Migration execution and registry bookkeeping are separate HTTP requests. A process crash can therefore leave a row in `running`, and multiple runners can race between registry lookup and the write that claims a migration.

Migration files remain ordered execution units: the runner sorts them by filename, executes one at a time, and stops at the first failure. The change must preserve that behavior while making claims safe across concurrent processes.

## Design

Normalize registry configuration once per public operation. `registry_ns` and `registry_db` default to the existing registry scope and are applied to `install_registry/2`, `status/2`, `run/2`, `reset/2`, and `rollback/2`. Registry requests use a client/request scope built from those values; migration SQL continues to use the original target client. The CLI maps `--registry-namespace` and `--registry-database` to the same Elixir option names.

Before executing a migration, the runner performs an atomic registry claim keyed by filename and checksum. A new row is claimed only if no row exists; a failed row is claimable only when `allow_failed_rerun?` is enabled; an existing `running` row remains an error by default. The claim result must prove that this runner won the conditional write before target SQL is sent, so two runners cannot both execute the same migration successfully.

Recovery is opt-in. `recover_running: true`, exposed as `--recover-running`, changes the preflight behavior for a matching `running` row: it atomically marks that row as failed/retryable with recovery metadata and then claims it through the normal retry path. The default remains a blocking `:migration_already_running` error. Operators must verify that the previous runner has stopped before using recovery.

The runner remains serial and fail-fast. A successful migration is marked `applied` before the next file begins. If target execution fails, the row is marked `failed` when possible and the batch stops. If the process crashes between the target request and registry update, the row may remain `running`; no automatic timeout or silent retry is introduced.

## Testing and documentation

Unit tests will assert registry headers/scope for every public operation, option normalization, default blocking, explicit recovery, atomic claim behavior, and fail-fast ordering. CLI helper tests will assert both option names and mappings. A live integration test will run migrations against one target namespace/database while storing the registry in a separate namespace/database, then verify status, reset, and rollback use that registry.

`docs/migrations.md` will document defaults, separate registry scope, serial ordering, crash failure model, and the required `--recover-running` procedure. Public function docs and task help text will use the same terminology.
