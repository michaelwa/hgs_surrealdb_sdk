# Migration Registry Correctness and Recovery Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make migration registry scope configuration correct across the API and CLI, and add explicit, concurrency-safe recovery for stale `running` rows.

**Architecture:** Normalize `registry_ns`, `registry_db`, and `recover_running?` into one migration configuration used by all public operations. Send registry queries through the configured registry scope while keeping migration SQL on the target scope. Claim each migration with a conditional registry write, preserve serial filename order and fail-fast execution, and require explicit recovery for stale claims.

**Tech Stack:** Elixir, ExUnit, Mix tasks, Req/HTTP SurrealDB client, SurrealQL, live SurrealDB integration tests, Markdown documentation.

## Global Constraints

- Preserve serial filename order and stop the batch after the first migration failure.
- `registry_ns` and `registry_db` must have identical semantics in the Elixir API and CLI.
- Default behavior for a `running` row remains a structured `:migration_already_running` error.
- Recovery is explicit via `recover_running: true` and `--recover-running`; never recover automatically by age.
- A runner must prove it won an atomic claim before sending migration SQL.
- Keep HTTP-only migration support and existing `run/2`, `status/2`, `reset/2`, and `rollback/2` return contracts unless a new structured error is required.

---

### Task 1: Define the registry configuration and scope boundary

**Files:**
- Modify: `lib/surreal_db/migrations.ex:1-115,117-245`
- Test: `test/surreal_db/migrations_test.exs:1-20,377-520`

**Interfaces:**
- Consumes: `SurrealDB.Client.t()` and keyword options passed to each public migration function.
- Produces: a normalized internal config containing `registry_ns`, `registry_db`, and `recover_running?`; every registry request uses that scope while target migration requests retain the original client scope.

- [ ] **Step 1: Write failing scope tests**

  Add tests that call `install_registry/2`, `status/2`, `run/2`, `reset/2`, and `rollback/2` with `registry_ns: "meta_ns", registry_db: "meta_db"`. Assert registry requests carry `ns: meta_ns` and `db: meta_db`, while the migration `up` request carries the target client’s original headers. Add a test that omitted options preserve the current default registry scope.

- [ ] **Step 2: Run the focused tests and verify failure**

  Run: `mix test test/surreal_db/migrations_test.exs`

  Expected: FAIL because current registry requests use the target client scope and the public option values are ignored.

- [ ] **Step 3: Implement normalized registry scope**

  Add private validation/configuration helpers in `SurrealDB.Migrations` that default the registry namespace/database and reject blank or non-string identifiers with `:invalid_migration_options`. Build a registry-scoped client or request context from the configured values without mutating the target client. Thread the resulting `registry` client and config through install, status, reset, run, and rollback helpers.

  Ensure `install_registry/2` actually uses `opts`; `status/2` and `reset/2` must install or otherwise target the configured registry consistently before querying/deleting; `run/2` must pass the configured registry client into `run_migrations`; `rollback/2` must use it for lookup and row deletion.

- [ ] **Step 4: Run the focused tests and verify scope behavior**

  Run: `mix test test/surreal_db/migrations_test.exs`

  Expected: PASS, including the new separate-registry request assertions and all existing migration behavior.

- [ ] **Step 5: Commit the scope boundary**

  Run: `git add lib/surreal_db/migrations.ex test/surreal_db/migrations_test.exs && git commit -m "fix: apply migration registry scope options"`

### Task 2: Make migration claims atomic and preserve serial fail-fast execution

**Files:**
- Modify: `lib/surreal_db/migrations.ex:376-632`
- Modify: `priv/schema_migrations/001_define_schema_migrations.surql`
- Test: `test/surreal_db/migrations_test.exs:54-375`

**Interfaces:**
- Consumes: normalized migration config from Task 1 and registry-scoped client.
- Produces: one claim path that returns `{:ok, :claimed}` only for the winning runner, keeps `running` rows blocking, and ensures `do_run_migrations/5` does not invoke the next file after an error.

- [ ] **Step 1: Write failing claim and ordering tests**

  Add tests asserting the claim query is conditional on filename/checksum/status and that a zero-row claim returns a structured concurrency error rather than executing target SQL. Add a test with two files where the first target request fails; assert no request for the second file is made. Add a test asserting the existing `running` row remains `:migration_already_running` without recovery.

- [ ] **Step 2: Run the focused tests and verify failure**

  Run: `mix test test/surreal_db/migrations_test.exs`

  Expected: FAIL because current `INSERT`/`UPDATE` paths do not prove ownership of the claim, and the tests expect the new conditional-write contract.

- [ ] **Step 3: Implement the atomic claim**

  Replace the preflight-to-write race with a conditional SurrealQL claim keyed by filename and checksum. Use a unique registry constraint on `filename` and an update/insert strategy whose returned rows identify whether this invocation claimed the migration. Check the returned row count/status before calling `SurrealDB.query(target, migration.up)`.

  Preserve the existing state machine: applied + same checksum skips, applied + changed checksum errors, failed requires `allow_failed_rerun?`, running blocks unless Task 3 recovery is enabled, and unsupported statuses error. Keep `do_run_migrations/5` fail-fast and retain the existing applied/failed bookkeeping after target execution.

- [ ] **Step 4: Update registry schema constraints**

  Add or correct the schema constraint/index required to make `filename` unique within the registry database. Keep existing fields and status values compatible with current rows; add any recovery metadata fields used by the claim/recovery query with safe defaults.

- [ ] **Step 5: Run focused unit tests**

  Run: `mix test test/surreal_db/migrations_test.exs`

  Expected: PASS, including atomic-claim, fail-fast, checksum, failed-rerun, and existing rollback tests.

- [ ] **Step 6: Commit the claim behavior**

  Run: `git add lib/surreal_db/migrations.ex priv/schema_migrations/001_define_schema_migrations.surql test/surreal_db/migrations_test.exs && git commit -m "fix: claim migrations atomically"`

### Task 3: Add explicit stale-running recovery

**Files:**
- Modify: `lib/surreal_db/migrations.ex:117-181,448-490,500-632`
- Modify: `priv/schema_migrations/001_define_schema_migrations.surql`
- Test: `test/surreal_db/migrations_test.exs:227-375`

**Interfaces:**
- Consumes: `recover_running?: boolean()` in normalized run config.
- Produces: `recover_running: true` recovery semantics that transition the matching row to retryable `failed` state and then use the existing failed-rerun claim path; default calls remain blocking.

- [ ] **Step 1: Write failing recovery tests**

  Add a test where a matching `running` row returns `:migration_already_running` with default options. Add a recovery test that passes `recover_running?: true`, asserts a conditional recovery update includes filename/checksum/status `running`, records a recovery error/message and increments `attempt_count`, then asserts the normal retry claim, target execution, and applied update occur. Add a test where the conditional recovery update affects zero rows and returns a structured concurrency error without target execution.

- [ ] **Step 2: Run the focused tests and verify failure**

  Run: `mix test test/surreal_db/migrations_test.exs`

  Expected: FAIL because `recover_running?` is not recognized and the current `running` branch always errors.

- [ ] **Step 3: Implement explicit recovery**

  Extend `build_run_config/1` with `recover_running?: Keyword.get(opts, :recover_running?, false)`. In the running-row preflight branch, keep the existing error unless that flag is true. When enabled, execute a conditional update matching filename, checksum, and `status = 'running'`; require one returned row, then route the row through the existing failed-rerun path with `allow_failed_rerun?` internally enabled for this recovery operation.

  Document in public function docs and error details that operators must confirm the previous runner is stopped before recovery. Do not add time-based stale detection or automatic retries.

- [ ] **Step 4: Run unit and regression tests**

  Run: `mix test test/surreal_db/migrations_test.exs`

  Expected: PASS with default blocking, explicit recovery, concurrent-loser protection, and all prior tests.

- [ ] **Step 5: Commit recovery policy**

  Run: `git add lib/surreal_db/migrations.ex priv/schema_migrations/001_define_schema_migrations.surql test/surreal_db/migrations_test.exs && git commit -m "feat: add explicit migration recovery"`

### Task 4: Align CLI options and task helper contracts

**Files:**
- Modify: `lib/mix/tasks/surreal/migration_task_helpers.ex:10-90`
- Modify: `lib/mix/tasks/surreal.migrate.ex:1-12`
- Modify: `lib/mix/tasks/surreal.migrations.ex:1-12`
- Modify: `lib/mix/tasks/surreal.rollback.ex:1-18`
- Modify: `lib/mix/tasks/surreal.setup.ex:1-14`
- Modify: `lib/mix/tasks/surreal.reset.ex:1-16`
- Test: `test/mix/tasks/surreal_migration_task_helpers_test.exs:138-190`

**Interfaces:**
- Consumes: CLI flags `--registry-namespace`, `--registry-database`, and `--recover-running`.
- Produces: `migration_opts/2` and `target_opts/2` containing `registry_ns`, `registry_db`, and `recover_running?` with the same semantics as the Elixir API.

- [ ] **Step 1: Write failing helper tests**

  Parse all new flags and assert `Helpers.migration_opts/2` and `Helpers.target_opts/2` emit the expected keyword options. Assert defaults omit overrides, `--recover-running` maps to `recover_running?: true`, and the help/module docs mention the flag and registry scope.

- [ ] **Step 2: Run helper tests and verify failure**

  Run: `mix test test/mix/tasks/surreal_migration_task_helpers_test.exs`

  Expected: FAIL because the switch list and option mappers do not contain the new flags.

- [ ] **Step 3: Implement CLI mapping**

  Add `registry_namespace: :string`, `registry_database: :string`, and `recover_running: :boolean` to the helper switches. Map them to `registry_ns`, `registry_db`, and `recover_running?` in both option builders. Ensure setup, reset, migrate, status, and rollback all call the appropriate builder so no task silently drops the options.

- [ ] **Step 4: Run helper and task regression tests**

  Run: `mix test test/mix/tasks/surreal_migration_task_helpers_test.exs test/mix/tasks`

  Expected: PASS with all existing CLI behavior unchanged.

- [ ] **Step 5: Commit CLI alignment**

  Run: `git add lib/mix/tasks/surreal lib/mix/tasks/surreal.migrate.ex lib/mix/tasks/surreal.migrations.ex lib/mix/tasks/surreal.rollback.ex lib/mix/tasks/surreal.setup.ex lib/mix/tasks/surreal.reset.ex test/mix/tasks/surreal_migration_task_helpers_test.exs && git commit -m "feat: expose migration registry options in CLI"`

### Task 5: Verify separate registry integration and document recovery policy

**Files:**
- Modify: `test/integration/migrations_integration_test.exs:1-120`
- Modify: `docs/migrations.md:24-140`
- Modify: `lib/mix/tasks/surreal.migrate.ex:1-12`
- Modify: `lib/mix/tasks/surreal.migrations.ex:1-12`
- Modify: `lib/mix/tasks/surreal.rollback.ex:1-18`

**Interfaces:**
- Consumes: completed API/CLI behavior from Tasks 1–4 and a live HTTP SurrealDB instance.
- Produces: an integration proof that target schema and registry are separate, plus operator-facing failure/recovery documentation.

- [ ] **Step 1: Write the live integration test**

  Create unique target and registry namespace/database identifiers. Run `install_registry`, `run`, `status`, and `rollback` with `registry_ns`/`registry_db` overrides. Assert the target table exists only in the target scope, registry rows are visible only in the registry scope, and the target database has no `schema_migrations` table. Add cleanup for both scopes and temporary migration files.

- [ ] **Step 2: Run the live migration integration test**

  Run: `mix test test/integration/migrations_integration_test.exs --include integration`

  Expected: PASS when the configured SurrealDB integration service is available; otherwise report the environment prerequisite rather than weakening the test.

- [ ] **Step 3: Update migration documentation and task help**

  Document default registry scope and `--registry-namespace` / `--registry-database`, explain that files run serially in filename order and stop on failure, describe how crashes can leave `running`, and provide the exact operator procedure:

  ```bash
  mix surreal.migrations --store MyApp.SurrealStore \
    --registry-namespace sdk_meta --registry-database migration_registry
  mix surreal.migrate --store MyApp.SurrealStore \
    --registry-namespace sdk_meta --registry-database migration_registry \
    --recover-running
  ```

  State that recovery must only be used after confirming the previous runner is no longer active. Explain that recovery is not automatic and that a migration may depend on earlier files.

- [ ] **Step 4: Run the complete verification suite**

  Run: `mix test`

  Expected: PASS for unit and task tests; integration tests pass when the project’s integration service is available.

- [ ] **Step 5: Commit integration and documentation**

  Run: `git add test/integration/migrations_integration_test.exs docs/migrations.md lib/mix/tasks/surreal.migrate.ex lib/mix/tasks/surreal.migrations.ex lib/mix/tasks/surreal.rollback.ex && git commit -m "docs: define migration registry recovery policy"`

## Final self-review checklist

- [ ] Every public migration operation applies registry scope options.
- [ ] Elixir and CLI option names map to the same behavior.
- [ ] A second concurrent runner cannot send target SQL after losing the claim.
- [ ] Files execute serially and the first failure stops the batch.
- [ ] `running` remains blocking unless explicit recovery is enabled.
- [ ] Separate-registry live integration coverage exists.
- [ ] Documentation explains dependencies, crash states, and operator recovery.
