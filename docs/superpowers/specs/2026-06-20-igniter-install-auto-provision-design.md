# Igniter installer — automatic namespace/database provisioning

Date: 2026-06-20
Status: Approved design, pending implementation plan
Roadmap item: N/A — install-ergonomics fix found while dogfooding
`mix igniter.install hgs_surrealdb_sdk` against a real Phoenix app.

## Problem

Running `mix igniter.install hgs_surrealdb_sdk@github:... --namespace app2
--database app2` writes config for `app2`/`app2` and prints a Notice saying to
"make sure the target namespace/database exist on the server" — but never says
what command does that. The natural guess, `mix surreal_db.create`, silently
ignores the configured store: `MigrationTaskHelpers.client_options/1`
(`lib/mix/tasks/surreal_db/migration_task_helpers.ex:210-218`) defaults
`namespace`/`database` to the hardcoded literal `"test"` whenever `--store`
isn't passed, so it creates `test/test` instead of `app2/app2` with no error or
warning. The first query against the real store then fails with "namespace
'app2' does not exist".

Two independent issues, both addressed here:

1. The installer never tells the user, or performs, the one extra step needed
   before the store works.
2. `surreal_db.create` (and every other `surreal_db.*` task, since they all
   funnel through the same helper) has a silent wrong-default footgun when
   `--store` is omitted.

## Non-goals

- Changing the DDL `create_database!`/`drop_database!` issue
  (`DEFINE NAMESPACE/DATABASE IF NOT EXISTS` is already idempotent and stays
  as-is).
- Adding a bespoke interactive "namespace/database missing, create? [Y/n]"
  prompt inside the installer's `igniter/1` callback. `igniter/1` is invoked
  during `--dry-run` previews and directly in unit tests
  (`Igniter.compose_task/3` in `hgs_surrealdb_sdk_install_test.exs`), so it
  must stay a pure, side-effect-free description of file changes — no network
  calls, no blocking stdin reads. Igniter's own `Igniter.add_task/3` mechanism
  (used internally for `deps.get`) is the supported way to run a real command
  after changes are reviewed and written, and it reuses Igniter's existing
  single "Proceed with changes? [Y/n]" confirmation instead of adding a second,
  redundant prompt.
- Supporting multiple SurrealDB servers/credentials per app beyond what
  `--store` selection already allows.

## Design

### 1. Store registry: `:surrealdb_stores`

Mirrors Ecto's `ecto_repos`. The installer appends the generated store module
to `config :app, :surrealdb_stores, [...]` instead of only writing the
per-store config block:

```elixir
|> Igniter.Project.Config.configure(
  "config.exs",
  app,
  [:surrealdb_stores],
  [store],
  updater: fn zipper -> Igniter.Code.List.prepend_new_to_list(zipper, store) end
)
```

First install creates `surrealdb_stores: [App.SurrealStore]`; a second install
(e.g. a second store) prepends and dedupes via the default `nodes_equal?`
equality predicate instead of clobbering the list. This registry is the
fallback lookup used by `MigrationTaskHelpers` (section 4) for any later manual
`surreal_db.*` invocation that omits `--store`.

### 2. Automatic provisioning via `Igniter.add_task`

The installer queues the creation task instead of only documenting it:

```elixir
|> Igniter.add_task("surreal_db.create", ["--store", inspect(store)])
```

`Igniter.add_task/3` appends to `igniter.tasks`, which Igniter displays
alongside the file diff and runs via `Mix.shell().cmd/1` *after* the user
confirms and the files are written (`deps/igniter/lib/igniter.ex:1212-1259`).
Confirming the install therefore also creates the `app2/app2` namespace and
database, with zero extra commands, in the common case where the dev SurrealDB
server is already reachable.

If the server isn't reachable, the subprocess exits non-zero and Igniter
prints "Task failed (exit code N): mix surreal_db.create --store ..." — but the
config/supervision-tree file changes are already safely on disk by that point,
so the user can just rerun the same command once the server is up. No new
error-handling code is needed for this path; it falls out of Igniter's
existing task-runner behavior plus the existing `Mix.raise` in
`MigrationTaskHelpers.unwrap!/1`.

### 3. Updated installer Notice

Replace the current "make sure the target namespace/database exist" line with
language describing what will happen automatically:

```
SurrealDB store #{inspect(store)} generated and added to your supervision tree.

Connection config written to config/config.exs (keyed by #{inspect(app)} /
#{inspect(store)}). The default credentials are root/root for a local dev
server. Override them (and the endpoint) per environment in
config/runtime.exs before deploying.

Confirming these changes will also run `mix surreal_db.create --store
#{inspect(store)}` to create the "#{namespace}/#{database}" namespace/database
on the target server. If the server isn't reachable yet, just run that
command yourself once it is up.

Call it without an explicit client, e.g. `#{inspect(store)}.query("INFO FOR DB")`.
```

### 4. No-surprises default removal in `MigrationTaskHelpers`

In `lib/mix/tasks/surreal_db/migration_task_helpers.ex`:

- Remove the `put_default(:namespace, "test")` / `put_default(:database,
  "test")` lines from `client_options/1` (`:210-218`). Keep the `:endpoint`
  default and the `root`/`root` auth default — a wrong endpoint just fails to
  connect; a wrong namespace silently succeeds against the wrong data, which
  is the actual footgun.
- When `--store`/`--repo` is absent, `store_options/1` (`:220-234`) now
  consults the registry instead of returning `[]` unconditionally:
  - **Exactly one** module in `Application.get_env(Mix.Project.config()[:app],
    :surrealdb_stores, [])` → use its `config/0` automatically (same
    ergonomics as `mix ecto.create` needing no `--repo` when there's one
    repo).
  - **Zero** registered → contribute nothing; CLI flags (if any) carry
    forward.
  - **Two or more** registered → `Mix.raise` asking for `--store`, *unless*
    the caller already passed explicit `--namespace` and `--database` (then
    they're bypassing stores entirely and the ambiguity is moot).
- After merging store config with CLI overrides, a final guard raises a clear
  `Mix.raise` if `namespace`/`database` are still unset — replacing the old
  silent `test/test` fallback with a message pointing at `--store`,
  `--namespace`/`--database`, or `mix igniter.install hgs_surrealdb_sdk`.

This fixes every `surreal_db.*` task at once (`create`, `drop`, `setup`,
`reset`, `migrate`, `migrations`, `rollback`, `load`, `dump` all call
`Helpers.build_client!/1`), not just `create`.

### 5. README

Update the "Igniter" section to state that the install command also creates
the namespace/database automatically (the queued task), and mention
`:surrealdb_stores` for anyone scripting `surreal_db.*` tasks by hand.

## Data flow

`mix igniter.install hgs_surrealdb_sdk --namespace app2 --database app2` →
`igniter/1` builds the store module, config writes (including
`:surrealdb_stores`), supervision-tree edit, Notice, and queues
`{"surreal_db.create", ["--store", "App.SurrealStore"]}` → Igniter renders the
diff + queued-task list → user confirms once → files are written → Igniter
runs `mix surreal_db.create --store App.SurrealStore` as a subprocess →
`MigrationTaskHelpers.build_client!/1` reads `App.SurrealStore.config/0`
(explicit `--store`, so the registry lookup isn't even consulted here) →
`create_database!/2` issues `DEFINE NAMESPACE IF NOT EXISTS app2; DEFINE
DATABASE IF NOT EXISTS app2;` → success message printed.

Later, a manual `mix surreal_db.create` (no flags) on the same project hits the
registry path: one store registered → auto-detected → same outcome without
needing `--store`.

## Error handling

- SurrealDB unreachable during the queued task: subprocess exits non-zero,
  Igniter reports the failed task, file changes remain applied, user reruns
  the command manually later. No swallowed errors.
- Ambiguous registry (2+ stores, no `--store`, no manual `--namespace`/
  `--database`): `Mix.raise` before any network call is attempted.
- No store anywhere and no manual scope: `Mix.raise` instead of the previous
  silent wrong-default.

## Backward compatibility

- Explicit `--store <Module>` usage is unchanged.
- Explicit `--namespace`/`--database` CLI usage (no store involved) is
  unchanged.
- Breaking (intentionally): any script currently relying on bare
  `mix surreal_db.create` (no flags) defaulting to `test/test` will now either
  auto-resolve to the real registered store (if exactly one) or raise. This is
  the bug being fixed, not a regression to guard against.

## Testing strategy

- `test/mix/tasks/hgs_surrealdb_sdk_install_test.exs`: assert the
  `surrealdb_stores` config is written; `assert_has_task(igniter,
  "surreal_db.create", ["--store", "Test.SurrealStore"])`; assert the updated
  Notice text via `assert_has_notice/2`.
- `test/mix/tasks/surreal_db_migration_task_helpers_test.exs`:
  - Switch the module to `async: false` — the new auto-detect path reads real
    `Application` env (`:surrealdb_stores`), which is global per-VM state.
  - Fix the two existing tests that implicitly relied on the removed
    `test/test` default (`"migration_opts defaults path and target..."` and
    `"target_opts maps rollback --all..."`) by adding explicit
    `--namespace`/`--database` flags — they were never actually testing
    namespace/database resolution, just migration path/step parsing.
  - Add: single registered store → auto-detected, no `--store` needed.
  - Add: zero stores + no flags → `Mix.raise`.
  - Add: two+ stores + no `--store` + no manual scope → `Mix.raise`
    (ambiguity).
  - Add: two+ stores + no `--store` + explicit `--namespace`/`--database` →
    succeeds via CLI override.
  - Each `Application.put_env/3` in these tests cleaned up via `on_exit/1`.

## Open questions

None outstanding — both architecture forks (registry vs. always requiring
`--store`; passive Notice vs. automatic `Igniter.add_task`) were resolved
during brainstorming.
