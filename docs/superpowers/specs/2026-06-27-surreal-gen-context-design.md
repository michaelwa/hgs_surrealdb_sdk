# `mix surreal.gen.context` Generator — Design Spec

**Date:** 2026-06-27
**Status:** Approved (design); implementation plan to follow
**Component:** `hgs_surrealdb_sdk` — mix tasks (igniter generator)
**Audience for execution:** sonnet/haiku agents working in the `hgs_surrealdb_sdk` repo

---

## 1. Problem & Goal

The SDK already scaffolds a store (`hgs_surrealdb_sdk.install`) and generates blank
timestamped migrations (`surreal.gen.migration`). What it lacks is a single command,
analogous to `mix phx.gen.context`, that scaffolds a complete vertical slice for a
SurrealDB-backed entity in the **consuming application**:

1. A **context module** (domain boundary with named CRUD).
2. A **migration** (SurrealQL `DEFINE TABLE` / `DEFINE FIELD`).
3. A **Zoi schema module** (`use SurrealDB.Schema`).

**Goal:** Add `mix surreal.gen.context` to the SDK. Running it inside a host app
(e.g. the `test_igniter` test bed) lands these three files in the host's standard
directory structure, wired to the host's existing `SurrealDB.Store`.

This spec covers **v1 scope only**. Explicitly out of scope: generated test files,
auto-translating SurrealQL constraints into Zoi refinements, and a `gen.schema` /
`gen.json` family split (see §10).

## 2. End State (acceptance summary)

Running, inside a host app already installed with the SDK:

```bash
mix surreal.gen.context Accounts User \
  name:string \
  email:string \
  middle_name:string? \
  age:int \
  "created_at:datetime|readonly|default=time::now()"
```

produces exactly three files (and a notice):

1. `lib/<app>/accounts/user.ex` — Zoi schema module, `table "user"`.
2. `priv/surreal_repo/migrations/<timestamp>_create_user.surql` — up/down migration.
3. `lib/<app>/accounts.ex` — context module with thin named delegations to the store.

The host app then `mix compile`s cleanly, and `mix surreal.migrate` applies the new
table.

## 3. Command Interface

```
mix surreal.gen.context <Context> <Schema> <field_spec>... [options]
```

| Arg | Meaning | Example | Result |
|-----|---------|---------|--------|
| `Context` | Context module (relative to app prefix) | `Accounts` | `TestIgniter.Accounts` |
| `Schema` | Schema module, **nested under context** | `User` | `TestIgniter.Accounts.User` |
| `field_spec...` | Zero or more field specs (§4) | `name:string` | see §4 |

**Options:**

| Option | Default | Purpose |
|--------|---------|---------|
| `--table` | snake_case singular of `Schema` (`User`→`user`) | Override SurrealDB table name |
| `--store` | the single entry in `:surrealdb_stores` config, else `<Prefix>.SurrealStore` | Store module the context delegates to |
| `--plural` | naive pluralization of the table name | Override plural used in function names (`list_users`) |
| `--repo-path` | resolved via `MigrationTaskHelpers.repo_path/1` (`--store` config → default `priv/surreal_repo`) | Where the migration lands |

**Validation / errors (via `Mix.raise`):**

- Missing `Context` or `Schema` arg → raise with usage.
- A field spec that doesn't match the grammar (§4) → raise naming the offending spec.
- An unknown base type → raise listing supported types.
- An unknown modifier keyword → raise listing supported modifiers.
- Zero field specs is **allowed** (generates an `id`-only table + empty-ish context).

## 4. Field-Spec Grammar

```
name : type [?] [ |modifier ]...
```

- The **first** `:` splits `name` from the typespec. (`name` is a valid Elixir/SurrealQL
  identifier: `[a-z][a-z0-9_]*`.)
- A trailing **`?`** on the type marks the field optional.
- **Modifiers** are **`|`-delimited**. `|` is chosen deliberately because SurrealQL
  uses `::` heavily (e.g. `time::now()`), so splitting modifiers on `:` would be
  ambiguous — `|` is not used by the SurrealQL we emit.
- A field arg containing modifiers or `()` must be shell-quoted by the caller.

**Supported modifiers (migration-only — they never touch the Zoi schema):**

| Modifier | Emits into `DEFINE FIELD` |
|----------|---------------------------|
| `readonly` | `READONLY` |
| `default=<surql>` | `DEFAULT <surql>` |
| `assert=<surql>` | `ASSERT <surql>` |
| `value=<surql>` | `VALUE <surql>` |

Modifier emission order in the generated field line is fixed and deterministic:
`TYPE … [READONLY] [DEFAULT …] [VALUE …] [ASSERT …]`. (Reproduces the working
`user_profile.surql` example, which emits `TYPE DATETIME READONLY DEFAULT time::now()`
and `TYPE DATETIME VALUE time::now()`; SurrealDB accepts this clause order.)

### 4.1 Type Map

| Spec type | SurrealDB `TYPE` | Zoi expression |
|-----------|------------------|----------------|
| `string` | `STRING` | `Zoi.string()` |
| `int` / `integer` | `INT` | `Zoi.integer()` |
| `float` | `FLOAT` | `Zoi.float()` |
| `bool` / `boolean` | `BOOL` | `Zoi.boolean()` |
| `datetime` | `DATETIME` | `Zoi.datetime()` |
| `decimal` | `DECIMAL` | `Zoi.decimal()` |
| `uuid` | `UUID` | `Zoi.string()` *(Zoi 0.18 has no native uuid)* |
| `array` | `ARRAY` | `Zoi.array(Zoi.any())` |
| `object` | `OBJECT` | `Zoi.object(%{})` |
| `record:<table>` | `record<table>` | `Zoi.string()` *(record id as string)* |

(`record:<table>` is the one type whose own argument uses `:` — it is parsed as part
of the **type token**, before any `|` modifier split, so `account:string` vs
`owner:record:account` are unambiguous: split name on first `:`, then the remaining
typespec is split on `|`; the first `|`-segment is the full type token incl. any
`record:<table>`.)

### 4.2 Optional handling

`name:type?` →
- Migration: `TYPE OPTION<TYPE>`
- Zoi: `<zoi_expr> |> Zoi.optional()`

## 5. Generated Files

### 5.1 Zoi schema — `lib/<app>/<context_snake>/<schema_snake>.ex`

```elixir
defmodule TestIgniter.Accounts.User do
  @moduledoc """
  SurrealDB schema for the `user` table.
  """
  use SurrealDB.Schema

  table "user"

  schema do
    Zoi.object(%{
      id: Zoi.string() |> Zoi.optional(),
      name: Zoi.string(),
      email: Zoi.string(),
      middle_name: Zoi.string() |> Zoi.optional(),
      age: Zoi.integer(),
      created_at: Zoi.datetime() |> Zoi.optional()
    })
  end
end
```

- `id` is **always** prepended as `Zoi.string() |> Zoi.optional()` (SurrealDB record id).
- Fields appear in declaration order.
- `readonly`/`default`/`assert`/`value` modifiers do **not** affect this file. (A field
  with a SurrealQL `default` is still emitted as `Zoi.optional()` here, since the value
  is DB-supplied — e.g. `created_at` above.)

### 5.2 Migration — `priv/surreal_repo/migrations/<ts>_create_<table>.surql`

Timestamp and path reuse `Mix.Tasks.Surreal.MigrationTaskHelpers` (`timestamp/0`-style
`%Y%m%d%H%M%S` and `repo_path/1` resolution). Format mirrors the existing
`surreal.gen.migration` template (`-- migrate:up` / `-- migrate:down`).

```sql
-- create_user

-- migrate:up
DEFINE TABLE user TYPE NORMAL SCHEMAFULL PERMISSIONS NONE;
DEFINE FIELD name ON user TYPE STRING;
DEFINE FIELD email ON user TYPE STRING;
DEFINE FIELD middle_name ON user TYPE OPTION<STRING>;
DEFINE FIELD age ON user TYPE INT;
DEFINE FIELD created_at ON user TYPE DATETIME READONLY DEFAULT time::now();

-- migrate:down
REMOVE TABLE user;
```

- `id` gets **no** `DEFINE FIELD` line (SurrealDB manages record ids).
- The `DEFINE TABLE` line is fixed: `TYPE NORMAL SCHEMAFULL PERMISSIONS NONE` (matches
  the existing `user_profile` example).

### 5.3 Context — `lib/<app>/<context_snake>.ex`

```elixir
defmodule TestIgniter.Accounts do
  @moduledoc """
  The Accounts context.
  """
  alias TestIgniter.Accounts.User
  alias TestIgniter.SurrealStore

  def list_users(filters \\ %{}), do: SurrealStore.all(User, filters)
  def get_user(id), do: SurrealStore.get(User, id)
  def create_user(attrs), do: SurrealStore.create(User, attrs)
  def update_user(id, attrs), do: SurrealStore.update(User, id, attrs)
  def delete_user(id), do: SurrealStore.delete(User, id)
end
```

- Function names use the **plural/singular** of the **table** name (`list_users`,
  `get_user`), not the module name.
- `SurrealStore` alias resolves to the `--store` value.
- **Exact store function names/arities are verified against `SurrealDB.Store` /
  `SurrealDB.Repo` during implementation** (e.g. confirm `all/2`, `get/2`, `create/2`,
  `update/3`, `delete/2`); the delegations are adjusted to whatever the real signatures
  are. If a store function takes a client-first arg, the connection-bound store wrapper
  (no client) is the one used.
- If the context module **already exists**, Igniter's module-create handles the
  conflict (the task should not silently overwrite — rely on Igniter's behavior and
  surface it). Re-running with a new schema under an existing context is a known
  limitation for v1 (documented in the notice).

## 6. Architecture & Module Layout (in the SDK)

New file: `lib/mix/tasks/surreal.gen.context.ex`, following the **same Igniter
availability guard** as `lib/mix/tasks/hgs_surrealdb_sdk.install.ex`:

```elixir
if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Surreal.Gen.Context do
    use Igniter.Mix.Task
    # info/2 + igniter/1
  end
else
  defmodule Mix.Tasks.Surreal.Gen.Context do
    use Mix.Task
    # run/1 prints the "requires igniter" guidance and exits 1
  end
end
```

**Pure helper modules (no Igniter, easily unit-tested):** put parsing/emitting logic
in a plain module so it can be tested without Igniter. Proposed:
`lib/mix/tasks/surreal/gen_context_builder.ex` (module
`Mix.Tasks.Surreal.GenContextBuilder`) exposing pure functions:

- `parse_field!(spec) -> %Field{name, type, optional?, modifiers}` (raises on bad spec)
- `zoi_expr(field) -> binary` (e.g. `"Zoi.string() |> Zoi.optional()"`)
- `define_field_line(field, table) -> binary`
- `pluralize(word) -> binary` (naive: `y`→`ies` when preceded by a consonant; `s`/`x`/
  `z`/`ch`/`sh`→`+es`; else `+s`)
- `singularize`/table-name derivation as needed

The Igniter `igniter/1` callback orchestrates: resolve app prefix + store, parse all
field specs, render the three file bodies via the builder, then:

- `Igniter.Project.Module.create_module(igniter, schema_mod, body)`
- `Igniter.Project.Module.create_module(igniter, context_mod, body)`
- `Igniter.create_new_file(igniter, migration_path, surql_body)`
- `Igniter.add_notice(igniter, "...run mix surreal.migrate...")`

Prefix/app resolution mirrors the installer:
`Igniter.Project.Module.module_name_prefix/1` and
`Igniter.Project.Application.app_name/1`.

Store resolution: read `:surrealdb_stores` from host config if available (the installer
writes it); else default `<Prefix>.SurrealStore`; always overridable via `--store`.

## 7. Error Handling

- All arg/spec validation happens **before** any file is created (fail fast, no partial
  writes). Parse every field spec up front; if any raises, abort.
- Unknown type / modifier → `Mix.raise` with the full supported list.
- Igniter handles file-exists/module-exists conflicts per its standard behavior; the
  task does not force-overwrite.

## 8. Testing (SDK suite)

Unit tests on the **pure builder** (no Igniter, no DB):

1. `parse_field!/1`: happy paths (each base type, optional `?`, `record:<table>`),
   each modifier, multiple modifiers, and raises (bad name, unknown type, unknown
   modifier, empty type).
2. `zoi_expr/1`: type map correctness + optional piping; confirms modifiers are ignored.
3. `define_field_line/2`: type map, `OPTION<>`, and deterministic modifier ordering
   (`TYPE … VALUE … DEFAULT … READONLY ASSERT …`).
4. `pluralize/1`: `user→users`, `class→classes`, `company→companies`, `box→boxes`.

An Igniter-level test (if the SDK already has an Igniter test helper pattern — check
existing tests first) asserting the three files are created with expected contents for
a representative invocation. If no such harness exists in the repo, this is optional
for v1 and the end-to-end check (§9) covers it instead.

## 9. End-to-End Verification (in `test_igniter`)

1. From `prototypes/hgs_surrealdb_sdk`, ensure the new task compiles: `mix compile`.
2. In `test_igniter`, point the dep at the working branch / local path as already
   configured, then run the example command from §2.
3. Assert the three files exist at the expected paths with expected content.
4. `mix compile` the host app cleanly.
5. (Optional, if a scratch SurrealDB is up) `mix surreal.migrate` and confirm the
   table is created — **scratch/dev db only**, never a real namespace/database.

## 10. Out of Scope (v1)

- Generated test files for the context (no SurrealDB sandbox exists).
- Auto-translating SurrealQL `ASSERT`/`DEFAULT` into Zoi refinements.
- Curated named validators (the `email`/`min=`/`max=` two-layer mapping) — possible v2.
- A separate `surreal.gen.schema` / `surreal.gen.migration`-composition split.
- Updating/extending an existing context with a second schema in one invocation.
- `belongs_to`/association graph generation beyond a plain `record<table>` field type.

## 11. Open Questions / Verify-During-Implementation

- Confirm exact `SurrealDB.Store` connection-bound function arities for `all/get/
  create/update/delete` and adjust the context delegations to match.
- Confirm the exact `MigrationTaskHelpers` function name(s) for timestamp generation
  (reuse rather than duplicate); if timestamp is a private `defp` in
  `surreal.gen.migration`, factor it into the helper or the builder.
- Confirm `Igniter.Project.Module.create_module/3` path conventions place nested schema
  modules at `lib/<app>/<context>/<schema>.ex` as expected.
