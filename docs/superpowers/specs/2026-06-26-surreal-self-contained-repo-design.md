# Self-Contained SurrealDB Repo — Design Spec

**Date:** 2026-06-26
**Status:** Approved (design); implementation plan to follow
**Component:** `hgs_surrealdb_sdk` — migration system, mix tasks, igniter installer
**Audience for execution:** sonnet/haiku agents working in the `hgs_surrealdb_sdk` repo

---

## 1. Problem & Goal

Today the SDK stores its migration registry in a **separate** namespace/database
(`sdk_meta` / `migration_registry`), tracking the real target via `target_ns` /
`target_db` columns. This decoupling makes tracking, testing, and maintenance hard
to follow and produces **drift**: dropping the target database leaves orphaned
"applied" rows in `sdk_meta`, so a later `migrate` skips work, and `reset` fails to
rebuild. Migration sources also live at a fixed `priv/surrealdb_migrations`, and
rollback requires a per-invocation `--down-path`.

**Goal:** When `hgs_surrealdb_sdk` is added to a project, everything it manages is
**self-contained within the namespace/database defined in `config/config.exs`**.
The migration registry becomes a table in the application's own database, and all
migration/seed sources live under a single configured **repo folder**. As a direct
consequence, `drop`/`reset` become correct by construction (the registry is dropped
with the database), eliminating the drift bug class.

This spec covers **new self-contained behavior only**. Migrating already-installed
projects (e.g. the `test_igniter` test bed currently on `sdk_meta`) is explicitly
**out of scope** — see §12.

## 2. End State (acceptance summary)

A fresh `mix igniter.install hgs_surrealdb_sdk` results in:

1. Store config in `config/config.exs` containing a `repo_path: "priv/surreal_repo"` key.
2. A scaffolded `priv/surreal_repo/migrations/` directory and `priv/surreal_repo/seeds.exs`.
3. `mix surreal.setup` creating the configured ns/db, installing a `schema_migrations`
   table **inside that database**, and running migrations from `priv/surreal_repo/migrations`.
4. No `sdk_meta` namespace, no `migration_registry` database, no `target_ns`/`target_db`
   columns anywhere.
5. `mix surreal.drop` / `mix surreal.reset` that are correct without any registry-clearing
   workaround.
6. `mix surreal.rollback` that runs reversal SurrealQL from the **same migration file**, with
   no `--down-path`.
7. A `mix surreal.seed` task that runs `priv/surreal_repo/seeds.exs`.

## 3. Configuration

The repo folder location is configured under the existing store config block:

```elixir
config :test_igniter, TestIgniter.SurrealStore,
  endpoint: "http://localhost:8000",
  namespace: "app2",
  database: "app2",
  username: "root",
  password: "root",
  repo_path: "priv/surreal_repo"   # NEW — default when absent
```

Derived paths:

- **migrations dir** = `Path.join(repo_path, "migrations")`
- **seeds file** = `Path.join(repo_path, "seeds.exs")`

`repo_path` defaults to `"priv/surreal_repo"` if the key is absent.

### Path precedence (mix task option resolution)

For commands that load migrations, resolve the migrations directory in this order:

1. Explicit `--migrations-path` / `--path` CLI option (kept for ad-hoc/manual use).
2. `<repo_path>/migrations`, where `repo_path` comes from the resolved store config.
3. Default `priv/surreal_repo/migrations` (when neither a store nor an explicit
   path is available, e.g. manual `--namespace/--database` runs). Add an optional
   `--repo-path` CLI option to override the repo root in store-less invocations.

The previous default of `priv/surrealdb_migrations` is **removed**.

## 4. Repo Folder Layout

```
priv/surreal_repo/
  migrations/
    20260626195721_user_profile.surql
  seeds.exs
```

## 5. Migration Registry (co-located)

`install_registry` runs against the **configured client** (the app's ns/db) — not a
separate registry client. The table is renamed `schema_migrations` and simplified
(no `target_ns`/`target_db`, no `migration_key`); uniqueness is on `filename`:

```surql
DEFINE TABLE IF NOT EXISTS schema_migrations SCHEMAFULL;

DEFINE FIELD IF NOT EXISTS filename      ON TABLE schema_migrations TYPE string;
DEFINE FIELD IF NOT EXISTS checksum      ON TABLE schema_migrations TYPE string;
DEFINE FIELD IF NOT EXISTS sdk_version   ON TABLE schema_migrations TYPE option<string>;
DEFINE FIELD IF NOT EXISTS status        ON TABLE schema_migrations TYPE string
  ASSERT $value IN ['running', 'applied', 'failed'];
DEFINE FIELD IF NOT EXISTS started_at    ON TABLE schema_migrations TYPE option<datetime>;
DEFINE FIELD IF NOT EXISTS finished_at   ON TABLE schema_migrations TYPE option<datetime>;
DEFINE FIELD IF NOT EXISTS applied_at    ON TABLE schema_migrations TYPE option<datetime>;
DEFINE FIELD IF NOT EXISTS duration_ms   ON TABLE schema_migrations TYPE option<int>;
DEFINE FIELD IF NOT EXISTS error_message ON TABLE schema_migrations TYPE option<string>;
DEFINE FIELD IF NOT EXISTS attempt_count ON TABLE schema_migrations TYPE int DEFAULT 1;
DEFINE FIELD IF NOT EXISTS created_at    ON TABLE schema_migrations TYPE datetime DEFAULT time::now();
DEFINE FIELD IF NOT EXISTS updated_at    ON TABLE schema_migrations TYPE datetime DEFAULT time::now();

DEFINE INDEX IF NOT EXISTS schema_migrations_filename
  ON TABLE schema_migrations FIELDS filename UNIQUE;

DEFINE INDEX IF NOT EXISTS schema_migrations_status
  ON TABLE schema_migrations FIELDS status;
```

All registry queries (`status`, `reset`, preflight lookup, `mark_running/applied/failed`,
rollback selection/delete) drop the `target_ns`/`target_db` WHERE clauses and the
`migration_key`, keying on `filename` instead. The registry schema file moves to
reflect the new name (e.g. `priv/surrealdb_migrations/sdk_registry/...` →
`priv/schema_migrations/001_define_schema_migrations.surql`); update
`@registry_schema_path` accordingly.

## 6. Migration File Format (up/down in one file)

Each `.surql` migration contains both sections, delimited by comment markers:

```surql
-- migrate:up
DEFINE TABLE user_profile SCHEMAFULL;
DEFINE FIELD email ON user_profile TYPE string;

-- migrate:down
REMOVE TABLE user_profile;
```

**Parser rules:**

- The `-- migrate:up` marker is **required**; its content runs on `migrate`.
- The `-- migrate:down` marker is **optional**; its content runs on `rollback`.
- Content between `-- migrate:up` and `-- migrate:down` (or EOF) = up SurrealQL.
- Content after `-- migrate:down` = down SurrealQL.
- Marker match is line-based, case-insensitive, tolerant of surrounding
  whitespace (e.g. `--migrate:up`, `-- migrate:up`).
- A file missing `-- migrate:up` is a hard error with a message pointing at the file.
- **Checksum** is computed over the **entire file** content (drift detection covers
  both sections).

## 7. Mix Task Behavior

| Task | Behavior |
|------|----------|
| `surreal.create` | Unchanged — defines ns/db. |
| `surreal.setup` | create ns/db → install `schema_migrations` in app db → run up migrations. |
| `surreal.migrate` | Run up sections of pending files from the resolved migrations dir; registry in app db. |
| `surreal.rollback --force` | Run the **down** section from each rolled-back migration file (resolved from migrations dir). No `--down-path`. If a file has no `-- migrate:down` section, remove the registry row but warn loudly that the schema was not changed (same UX as the previously chosen warn-and-continue behavior, now sourced from the repo). |
| `surreal.drop --force` | Drop the database. Registry is co-located, so it is removed automatically — **remove the `clear_registry!` call**. |
| `surreal.reset --force` | drop → create → migrate. Naturally clean — **remove the `clear_registry!` call**. |
| `surreal.migrations` | List `schema_migrations` rows from the app db. |
| `surreal.seed` (NEW) | Resolve `<repo_path>/seeds.exs` and evaluate it after `app.start` so the store API is available. Supports `--repo-path` override. No-op with a friendly message if the file is absent. |
| `surreal.gen.migration NAME` | Write `<repo_path>/migrations/<ts>_<name>.surql` scaffolded with `-- migrate:up` and `-- migrate:down` sections. |

`MigrationTaskHelpers` gains repo-path resolution (read `:repo_path` from the resolved
store config, apply precedence from §3) and **loses** `clear_registry!/2`, the
`registry_ns`/`registry_db` options, and the `--down-path` option/handling.

## 8. gen.migration & seeds scaffolding

`surreal.gen.migration` template:

```surql
-- <name>

-- migrate:up


-- migrate:down

```

Installer-created `priv/surreal_repo/seeds.exs` template (illustrative):

```elixir
# Seed script for the SurrealDB store. Run with: mix surreal.seed
# The store API is available, e.g.:
#
#   TestIgniter.SurrealStore.create(TestIgniter.User, %{name: "Jane"})
```

## 9. Igniter Installer Changes (`hgs_surrealdb_sdk.install`)

In addition to current behavior (create store module, write connection config, add
supervision child, run `surreal.create`):

- Write `repo_path: "priv/surreal_repo"` into the store config block.
- Create `priv/surreal_repo/migrations/` (with a `.gitkeep`) and a template
  `priv/surreal_repo/seeds.exs`.
- Update the post-install notice to mention `repo_path`, `mix surreal.gen.migration`,
  `mix surreal.migrate`, and `mix surreal.seed`.

## 10. Removed / Breaking (SDK is 0.1.0 — acceptable, no shims)

- `sdk_meta` / `migration_registry` defaults; `@default_registry_ns`, `@default_registry_db`.
- `registry_client/2` and the separate-scope concept.
- `--registry-namespace` / `--registry-database` CLI options.
- `--down-path` CLI option and all down-path handling.
- `target_ns` / `target_db` columns + their indexes; `migration_key`.
- `MigrationTaskHelpers.clear_registry!/2` and its call sites in `drop`/`reset`.
- `priv/surrealdb_migrations` default path.

YAGNI: no backward-compatibility shims or dual-read of the old registry.

## 11. Testing

**Unit (scripted `Req` adapter, async):**
- `install_registry` issues its DEFINE against the **app** ns/db (assert `ns`/`db`
  headers equal the configured scope, not `sdk_meta`).
- Registry queries key on `filename` only (no `target_ns`/`target_db` in bodies).
- Migration parser: splits up/down; up-only file (no down); missing `-- migrate:up`
  errors; case/whitespace tolerance; checksum over full file.
- `rollback` executes the down section content against the target.
- `MigrationTaskHelpers`: repo-path resolution precedence (explicit path > store
  `repo_path` > default); `clear_registry!` removed.
- `gen.migration` writes both sections at `<repo_path>/migrations`.
- `surreal.seed` resolves and evaluates the seeds file (or no-ops cleanly when absent).

**End-to-end (manual checklist, against a scratch scope):**
- Always pass literal `--namespace X --database X` (a throwaway like `sdk_verify`);
  never run bare destructive tasks — a registered store makes them target the real
  configured db.
- setup → migrate (skip on rerun) → rollback (down section runs; table removed) →
  drop (db + registry gone) → reset (rebuilds from empty) → seed.

## 12. Out of Scope

- Migrating the already-installed `test_igniter` project off `sdk_meta` (move files,
  convert format, re-home registry, drop `sdk_meta`). New behavior only; re-aligning
  `test_igniter` is a later manual step or a clean re-setup.
- Multi-store remains supported (each store carries its own `repo_path`, and its
  registry lives in its own db) but is not a focus of this work.

## 13. Affected Files (orientation for the plan)

- `lib/surreal_db/migrations.ex` — co-locate registry, rename table, add section
  parser, rollback from same file, remove registry_client/down_path/target columns.
- `priv/.../*.surql` — new `schema_migrations` schema file (renamed/relocated path).
- `lib/mix/tasks/surreal/migration_task_helpers.ex` — repo_path resolution; remove
  `clear_registry!`, `--down-path`, registry-scope options.
- `lib/mix/tasks/surreal.{migrate,rollback,drop,reset,setup,migrations,gen.migration}.ex`.
- `lib/mix/tasks/surreal.seed.ex` — NEW.
- `lib/mix/tasks/surreal.ex` — help text (add `surreal.seed`, adjust descriptions).
- `lib/mix/tasks/hgs_surrealdb_sdk.install.ex` — repo_path config + scaffold dirs/seeds.
- `test/surreal_db/migrations_test.exs`, `test/mix/tasks/surreal_migration_task_helpers_test.exs`,
  plus new parser/seed/gen tests.
