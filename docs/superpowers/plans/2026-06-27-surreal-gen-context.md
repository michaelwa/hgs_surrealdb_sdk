# `mix surreal.gen.context` Generator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `mix surreal.gen.context` Igniter generator to the `hgs_surrealdb_sdk` that scaffolds a context module, a Zoi schema module, and a SurrealQL migration into a consuming Phoenix application.

**Architecture:** A pure, Mix/Igniter-free builder module (`Mix.Tasks.Surreal.GenContextBuilder`) does all parsing and string rendering and is unit-tested in isolation. A thin Igniter task (`Mix.Tasks.Surreal.Gen.Context`) resolves app/module/store/path context, calls the builder, and creates the files via Igniter. The task mirrors the existing `hgs_surrealdb_sdk.install` task's Igniter-availability guard.

**Tech Stack:** Elixir, Igniter `~> 0.5` (installed: 0.8.0, optional dep), Zoi `~> 0.7` (installed: 0.18.4), ExUnit, `Igniter.Test`.

## Global Constraints

- All work happens in the SDK checkout at `../../prototypes/hgs_surrealdb_sdk` (NOT `deps/`).
- The generator lives in the SDK; generated files land in the **consuming** app.
- Igniter is an **optional** dependency — the task module MUST be wrapped in
  `if Code.ensure_loaded?(Igniter) do … else … end` with a graceful fallback, exactly
  like `lib/mix/tasks/hgs_surrealdb_sdk.install.ex`.
- Builder functions are **pure** (except `timestamp/0`); they may call `Mix.raise/1`
  for validation (raises `Mix.Error`).
- Field-modifier clause order in `DEFINE FIELD`: `TYPE … [READONLY] [DEFAULT …] [VALUE …] [ASSERT …]`.
- Type map (verbatim from spec §4.1):
  `string→STRING/Zoi.string()`, `int|integer→INT/Zoi.integer()`, `float→FLOAT/Zoi.float()`,
  `bool|boolean→BOOL/Zoi.boolean()`, `datetime→DATETIME/Zoi.datetime()`,
  `decimal→DECIMAL/Zoi.decimal()`, `uuid→UUID/Zoi.string()`,
  `array→ARRAY/Zoi.array(Zoi.any())`, `object→OBJECT/Zoi.object(%{})`,
  `record:<table>→record<table>/Zoi.string()`.
- Store connection-bound CRUD arities (verbatim from `lib/surreal_db/store.ex`):
  `all(schema, filters \\ %{}, opts \\ [])`, `get(schema, id, opts \\ [])`,
  `create(schema, attrs, opts \\ [])`, `update(schema, id, attrs, opts \\ [])`,
  `delete(schema, id, opts \\ [])`.

---

## File Structure

| Path | Responsibility |
|------|----------------|
| `lib/mix/tasks/surreal/gen_context_builder.ex` (create) | Pure parsing + rendering. `Field` struct, `parse_field!/1`, `parse_fields!/1`, `zoi_expr/1`, `define_field_line/2`, `pluralize/1`, `table_name/1`, `migration_filename/2`, `timestamp/0`, `migration_body/3`, `schema_module_body/2`, `context_module_body/5`. |
| `lib/mix/tasks/surreal.gen.context.ex` (create) | Igniter task: resolve prefix/store/path, call builder, create files. Plus `else`-branch Mix.Task fallback. |
| `test/mix/tasks/surreal_gen_context_builder_test.exs` (create) | Unit tests for every builder function. |
| `test/mix/tasks/surreal_gen_context_test.exs` (create) | `Igniter.Test` integration test for the task. |

---

## Task 1: Field struct + parser

**Files:**
- Create: `lib/mix/tasks/surreal/gen_context_builder.ex`
- Test: `test/mix/tasks/surreal_gen_context_builder_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Mix.Tasks.Surreal.GenContextBuilder.Field` struct with fields
    `name :: String.t()`, `surreal_type :: String.t()`, `zoi_base :: String.t()`,
    `optional? :: boolean()` (default `false`), `modifiers :: [{atom(), String.t() | nil}]` (default `[]`).
  - `parse_field!(spec :: String.t()) :: Field.t()` — raises `Mix.Error` on bad input.
  - `parse_fields!(specs :: [String.t()]) :: [Field.t()]`.

- [ ] **Step 1: Write the failing test**

Create `test/mix/tasks/surreal_gen_context_builder_test.exs`:

```elixir
defmodule Mix.Tasks.Surreal.GenContextBuilderTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Surreal.GenContextBuilder, as: Builder
  alias Mix.Tasks.Surreal.GenContextBuilder.Field

  describe "parse_field!/1" do
    test "parses a plain string field" do
      assert %Field{
               name: "name",
               surreal_type: "STRING",
               zoi_base: "Zoi.string()",
               optional?: false,
               modifiers: []
             } = Builder.parse_field!("name:string")
    end

    test "marks ? suffix optional" do
      assert %Field{name: "middle_name", surreal_type: "STRING", optional?: true} =
               Builder.parse_field!("middle_name:string?")
    end

    test "maps integer aliases and other base types" do
      assert %Field{surreal_type: "INT", zoi_base: "Zoi.integer()"} = Builder.parse_field!("age:int")
      assert %Field{surreal_type: "INT"} = Builder.parse_field!("age:integer")
      assert %Field{surreal_type: "DATETIME", zoi_base: "Zoi.datetime()"} =
               Builder.parse_field!("at:datetime")
      assert %Field{surreal_type: "ARRAY", zoi_base: "Zoi.array(Zoi.any())"} =
               Builder.parse_field!("tags:array")
    end

    test "parses record:<table> reference type" do
      assert %Field{surreal_type: "record<account>", zoi_base: "Zoi.string()", optional?: true} =
               Builder.parse_field!("owner:record:account?")
    end

    test "parses |-delimited modifiers without splitting SurrealQL ::" do
      assert %Field{
               name: "created_at",
               surreal_type: "DATETIME",
               optional?: false,
               modifiers: [{:readonly, nil}, {:default, "time::now()"}]
             } = Builder.parse_field!("created_at:datetime|readonly|default=time::now()")
    end

    test "raises on missing type" do
      assert_raise Mix.Error, fn -> Builder.parse_field!("name:") end
      assert_raise Mix.Error, fn -> Builder.parse_field!("name") end
    end

    test "raises on bad field name" do
      assert_raise Mix.Error, fn -> Builder.parse_field!("Name:string") end
    end

    test "raises on unknown type" do
      assert_raise Mix.Error, fn -> Builder.parse_field!("name:widget") end
    end

    test "raises on unknown modifier" do
      assert_raise Mix.Error, fn -> Builder.parse_field!("name:string|frobnicate") end
    end
  end

  test "parse_fields!/1 maps a list" do
    assert [%Field{name: "a"}, %Field{name: "b"}] =
             Builder.parse_fields!(["a:string", "b:int"])
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/mix/tasks/surreal_gen_context_builder_test.exs`
Expected: FAIL with `module Mix.Tasks.Surreal.GenContextBuilder is not available` (or undefined).

- [ ] **Step 3: Write minimal implementation**

Create `lib/mix/tasks/surreal/gen_context_builder.ex`:

```elixir
defmodule Mix.Tasks.Surreal.GenContextBuilder do
  @moduledoc false
  # Pure parsing + rendering helpers for `mix surreal.gen.context`.
  # No Igniter/Mix.Task dependency; only `Mix.raise/1` for validation.

  defmodule Field do
    @moduledoc false
    defstruct [:name, :surreal_type, :zoi_base, optional?: false, modifiers: []]
  end

  @type_map %{
    "string" => {"STRING", "Zoi.string()"},
    "int" => {"INT", "Zoi.integer()"},
    "integer" => {"INT", "Zoi.integer()"},
    "float" => {"FLOAT", "Zoi.float()"},
    "bool" => {"BOOL", "Zoi.boolean()"},
    "boolean" => {"BOOL", "Zoi.boolean()"},
    "datetime" => {"DATETIME", "Zoi.datetime()"},
    "decimal" => {"DECIMAL", "Zoi.decimal()"},
    "uuid" => {"UUID", "Zoi.string()"},
    "array" => {"ARRAY", "Zoi.array(Zoi.any())"},
    "object" => {"OBJECT", "Zoi.object(%{})"}
  }

  @name_re ~r/^[a-z][a-z0-9_]*$/

  def parse_fields!(specs) when is_list(specs), do: Enum.map(specs, &parse_field!/1)

  def parse_field!(spec) when is_binary(spec) do
    case String.split(spec, ":", parts: 2) do
      [name, rest] when name != "" and rest != "" ->
        unless Regex.match?(@name_re, name) do
          Mix.raise(~s(invalid field name "#{name}" in "#{spec}"; must match [a-z][a-z0-9_]*))
        end

        [type_token | mod_tokens] = String.split(rest, "|")
        {surreal_type, zoi_base, optional?} = parse_type!(type_token, spec)
        modifiers = Enum.map(mod_tokens, &parse_modifier!(&1, spec))

        %Field{
          name: name,
          surreal_type: surreal_type,
          zoi_base: zoi_base,
          optional?: optional?,
          modifiers: modifiers
        }

      _ ->
        Mix.raise(~s(invalid field spec "#{spec}"; expected name:type[?][|modifier]...))
    end
  end

  defp parse_type!(token, spec) do
    {base, optional?} =
      if String.ends_with?(token, "?") do
        {String.trim_trailing(token, "?"), true}
      else
        {token, false}
      end

    case base do
      "record:" <> table when table != "" ->
        {"record<#{table}>", "Zoi.string()", optional?}

      _ ->
        case Map.fetch(@type_map, base) do
          {:ok, {surreal_type, zoi_base}} -> {surreal_type, zoi_base, optional?}
          :error -> Mix.raise(~s(unknown type "#{base}" in "#{spec}"; supported: #{supported_types()}))
        end
    end
  end

  defp parse_modifier!(token, spec) do
    case String.split(token, "=", parts: 2) do
      ["readonly"] -> {:readonly, nil}
      ["default", v] when v != "" -> {:default, v}
      ["assert", v] when v != "" -> {:assert, v}
      ["value", v] when v != "" -> {:value, v}
      _ -> Mix.raise(~s(unknown modifier "#{token}" in "#{spec}"; supported: readonly, default=, assert=, value=))
    end
  end

  defp supported_types do
    (Map.keys(@type_map) ++ ["record:<table>"]) |> Enum.sort() |> Enum.join(", ")
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/mix/tasks/surreal_gen_context_builder_test.exs`
Expected: PASS (all `parse_field!`/`parse_fields!` tests green).

- [ ] **Step 5: Commit**

```bash
git add lib/mix/tasks/surreal/gen_context_builder.ex test/mix/tasks/surreal_gen_context_builder_test.exs
git commit -m "feat: add field-spec parser for surreal.gen.context builder"
```

---

## Task 2: Field emitters (Zoi + DEFINE FIELD)

**Files:**
- Modify: `lib/mix/tasks/surreal/gen_context_builder.ex`
- Test: `test/mix/tasks/surreal_gen_context_builder_test.exs`

**Interfaces:**
- Consumes: `Field` struct from Task 1.
- Produces:
  - `zoi_expr(Field.t()) :: String.t()` — e.g. `"Zoi.string() |> Zoi.optional()"`.
  - `define_field_line(Field.t(), table :: String.t()) :: String.t()` — one `DEFINE FIELD …;` line.

- [ ] **Step 1: Write the failing test**

Append to `test/mix/tasks/surreal_gen_context_builder_test.exs`, inside the module:

```elixir
  describe "zoi_expr/1" do
    test "returns base for required field" do
      assert "Zoi.string()" == Builder.zoi_expr(Builder.parse_field!("name:string"))
    end

    test "pipes optional for ? field" do
      assert "Zoi.string() |> Zoi.optional()" ==
               Builder.zoi_expr(Builder.parse_field!("nick:string?"))
    end

    test "ignores migration-only modifiers" do
      assert "Zoi.datetime()" ==
               Builder.zoi_expr(Builder.parse_field!("at:datetime|readonly|default=time::now()"))
    end
  end

  describe "define_field_line/2" do
    test "plain required field" do
      assert "DEFINE FIELD name ON user TYPE STRING;" ==
               Builder.define_field_line(Builder.parse_field!("name:string"), "user")
    end

    test "optional wraps in OPTION<>" do
      assert "DEFINE FIELD nick ON user TYPE OPTION<STRING>;" ==
               Builder.define_field_line(Builder.parse_field!("nick:string?"), "user")
    end

    test "emits modifiers in READONLY DEFAULT VALUE ASSERT order" do
      field = Builder.parse_field!("created_at:datetime|default=time::now()|readonly")

      assert "DEFINE FIELD created_at ON user TYPE DATETIME READONLY DEFAULT time::now();" ==
               Builder.define_field_line(field, "user")
    end

    test "emits assert last and value clause" do
      assert "DEFINE FIELD email ON acct TYPE STRING ASSERT $value.is_email();" ==
               Builder.define_field_line(Builder.parse_field!("email:string|assert=$value.is_email()"), "acct")

      assert "DEFINE FIELD updated_at ON acct TYPE DATETIME VALUE time::now();" ==
               Builder.define_field_line(Builder.parse_field!("updated_at:datetime|value=time::now()"), "acct")
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/mix/tasks/surreal_gen_context_builder_test.exs`
Expected: FAIL with `undefined function zoi_expr/1` (and `define_field_line/2`).

- [ ] **Step 3: Write minimal implementation**

Add to `Mix.Tasks.Surreal.GenContextBuilder` (before the private helpers):

```elixir
  def zoi_expr(%Field{zoi_base: base, optional?: false}), do: base
  def zoi_expr(%Field{zoi_base: base, optional?: true}), do: base <> " |> Zoi.optional()"

  def define_field_line(%Field{} = field, table) do
    type = if field.optional?, do: "OPTION<#{field.surreal_type}>", else: field.surreal_type
    "DEFINE FIELD #{field.name} ON #{table} TYPE #{type}#{modifier_clauses(field.modifiers)};"
  end

  # Deterministic clause order: READONLY, DEFAULT, VALUE, ASSERT.
  defp modifier_clauses(modifiers) do
    [:readonly, :default, :value, :assert]
    |> Enum.map(fn key -> {key, List.keyfind(modifiers, key, 0)} end)
    |> Enum.reduce("", fn
      {:readonly, {:readonly, _}}, acc -> acc <> " READONLY"
      {:default, {:default, v}}, acc -> acc <> " DEFAULT #{v}"
      {:value, {:value, v}}, acc -> acc <> " VALUE #{v}"
      {:assert, {:assert, v}}, acc -> acc <> " ASSERT #{v}"
      {_key, nil}, acc -> acc
    end)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/mix/tasks/surreal_gen_context_builder_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/mix/tasks/surreal/gen_context_builder.ex test/mix/tasks/surreal_gen_context_builder_test.exs
git commit -m "feat: add zoi + DEFINE FIELD emitters to gen.context builder"
```

---

## Task 3: Naming helpers (pluralize + table name)

**Files:**
- Modify: `lib/mix/tasks/surreal/gen_context_builder.ex`
- Test: `test/mix/tasks/surreal_gen_context_builder_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `pluralize(word :: String.t()) :: String.t()`.
  - `table_name(schema_arg :: String.t()) :: String.t()` — snake_case of the last module segment.

- [ ] **Step 1: Write the failing test**

Append inside the test module:

```elixir
  describe "pluralize/1" do
    test "regular adds s" do
      assert "users" == Builder.pluralize("user")
      assert "days" == Builder.pluralize("day")
    end

    test "sibilants add es" do
      assert "classes" == Builder.pluralize("class")
      assert "boxes" == Builder.pluralize("box")
      assert "buzzes" == Builder.pluralize("buzz")
      assert "watches" == Builder.pluralize("watch")
      assert "dishes" == Builder.pluralize("dish")
    end

    test "consonant + y becomes ies" do
      assert "companies" == Builder.pluralize("company")
    end
  end

  describe "table_name/1" do
    test "snake_cases the schema argument" do
      assert "user" == Builder.table_name("User")
      assert "user_profile" == Builder.table_name("UserProfile")
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/mix/tasks/surreal_gen_context_builder_test.exs`
Expected: FAIL with `undefined function pluralize/1`.

- [ ] **Step 3: Write minimal implementation**

Add to the builder:

```elixir
  def pluralize(word) when is_binary(word) do
    cond do
      Regex.match?(~r/(s|x|z|ch|sh)$/, word) -> word <> "es"
      Regex.match?(~r/[^aeiou]y$/, word) -> String.slice(word, 0..-2//1) <> "ies"
      true -> word <> "s"
    end
  end

  def table_name(schema_arg) when is_binary(schema_arg) do
    schema_arg
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/mix/tasks/surreal_gen_context_builder_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/mix/tasks/surreal/gen_context_builder.ex test/mix/tasks/surreal_gen_context_builder_test.exs
git commit -m "feat: add pluralize + table_name helpers to gen.context builder"
```

---

## Task 4: Body renderers (schema, context, migration)

**Files:**
- Modify: `lib/mix/tasks/surreal/gen_context_builder.ex`
- Test: `test/mix/tasks/surreal_gen_context_builder_test.exs`

**Interfaces:**
- Consumes: `Field`, `zoi_expr/1`, `define_field_line/2`.
- Produces:
  - `timestamp() :: String.t()` — UTC `%Y%m%d%H%M%S`.
  - `migration_filename(ts :: String.t(), migration_name :: String.t()) :: String.t()`.
  - `migration_body(table, migration_name, fields :: [Field.t()]) :: String.t()`.
  - `schema_module_body(table :: String.t(), fields :: [Field.t()]) :: String.t()` — module **body** (no `defmodule`).
  - `context_module_body(context_mod :: module, schema_mod :: module, store_mod :: module, singular :: String.t(), plural :: String.t()) :: String.t()` — module **body**.

Note: module bodies omit the `defmodule … do/end` wrapper because
`Igniter.Project.Module.create_module/3` adds it (see existing install task).

- [ ] **Step 1: Write the failing test**

Append inside the test module:

```elixir
  describe "migration rendering" do
    test "migration_filename joins timestamp and name" do
      assert "20260627000000_create_user.surql" ==
               Builder.migration_filename("20260627000000", "create_user")
    end

    test "migration_body renders up/down with field lines" do
      fields = Builder.parse_fields!(["name:string", "nick:string?"])

      assert Builder.migration_body("user", "create_user", fields) == """
             -- create_user

             -- migrate:up
             DEFINE TABLE user TYPE NORMAL SCHEMAFULL PERMISSIONS NONE;
             DEFINE FIELD name ON user TYPE STRING;
             DEFINE FIELD nick ON user TYPE OPTION<STRING>;

             -- migrate:down
             REMOVE TABLE user;
             """
    end
  end

  describe "schema_module_body/2" do
    test "renders use, table, and Zoi object with id first" do
      fields = Builder.parse_fields!(["name:string", "age:int?"])
      body = Builder.schema_module_body("user", fields)

      assert body =~ "use SurrealDB.Schema"
      assert body =~ ~s(table "user")
      assert body =~ "id: Zoi.string() |> Zoi.optional()"
      assert body =~ "name: Zoi.string()"
      assert body =~ "age: Zoi.integer() |> Zoi.optional()"
      assert body =~ "Zoi.object(%{"
    end
  end

  describe "context_module_body/5" do
    test "renders aliases and delegating CRUD functions" do
      body =
        Builder.context_module_body(
          MyApp.Accounts,
          MyApp.Accounts.User,
          MyApp.SurrealStore,
          "user",
          "users"
        )

      assert body =~ "alias MyApp.Accounts.User"
      assert body =~ "alias MyApp.SurrealStore"
      assert body =~ "def list_users(filters \\\\ %{}), do: SurrealStore.all(User, filters)"
      assert body =~ "def get_user(id), do: SurrealStore.get(User, id)"
      assert body =~ "def create_user(attrs), do: SurrealStore.create(User, attrs)"
      assert body =~ "def update_user(id, attrs), do: SurrealStore.update(User, id, attrs)"
      assert body =~ "def delete_user(id), do: SurrealStore.delete(User, id)"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/mix/tasks/surreal_gen_context_builder_test.exs`
Expected: FAIL with `undefined function migration_filename/2` (etc.).

- [ ] **Step 3: Write minimal implementation**

Add to the builder:

```elixir
  def timestamp, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")

  def migration_filename(timestamp, migration_name), do: "#{timestamp}_#{migration_name}.surql"

  def migration_body(table, migration_name, fields) do
    field_lines =
      fields
      |> Enum.map(&define_field_line(&1, table))
      |> Enum.join("\n")

    """
    -- #{migration_name}

    -- migrate:up
    DEFINE TABLE #{table} TYPE NORMAL SCHEMAFULL PERMISSIONS NONE;
    #{field_lines}

    -- migrate:down
    REMOVE TABLE #{table};
    """
  end

  def schema_module_body(table, fields) do
    Enum.join(
      [
        ~s(@moduledoc """),
        "SurrealDB schema for the `#{table}` table.",
        ~s("""),
        "use SurrealDB.Schema",
        "",
        "table #{inspect(table)}",
        "",
        "schema do",
        "  Zoi.object(%{",
        zoi_object_lines(fields),
        "  })",
        "end"
      ],
      "\n"
    )
  end

  def context_module_body(context_mod, schema_mod, store_mod, singular, plural) do
    schema_alias = module_last(schema_mod)
    store_alias = module_last(store_mod)

    Enum.join(
      [
        ~s(@moduledoc """),
        "The #{module_last(context_mod)} context.",
        ~s("""),
        "alias #{inspect(schema_mod)}",
        "alias #{inspect(store_mod)}",
        "",
        "def list_#{plural}(filters \\\\ %{}), do: #{store_alias}.all(#{schema_alias}, filters)",
        "def get_#{singular}(id), do: #{store_alias}.get(#{schema_alias}, id)",
        "def create_#{singular}(attrs), do: #{store_alias}.create(#{schema_alias}, attrs)",
        "def update_#{singular}(id, attrs), do: #{store_alias}.update(#{schema_alias}, id, attrs)",
        "def delete_#{singular}(id), do: #{store_alias}.delete(#{schema_alias}, id)"
      ],
      "\n"
    )
  end

  defp zoi_object_lines(fields) do
    [{"id", "Zoi.string() |> Zoi.optional()"} | Enum.map(fields, &{&1.name, zoi_expr(&1)})]
    |> Enum.map(fn {name, expr} -> "    #{name}: #{expr}" end)
    |> Enum.join(",\n")
  end

  defp module_last(mod) do
    mod
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
    |> String.split(".")
    |> List.last()
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/mix/tasks/surreal_gen_context_builder_test.exs`
Expected: PASS (full builder suite green).

- [ ] **Step 5: Commit**

```bash
git add lib/mix/tasks/surreal/gen_context_builder.ex test/mix/tasks/surreal_gen_context_builder_test.exs
git commit -m "feat: add schema/context/migration body renderers to gen.context builder"
```

---

## Task 5: Igniter task + integration test

**Files:**
- Create: `lib/mix/tasks/surreal.gen.context.ex`
- Test: `test/mix/tasks/surreal_gen_context_test.exs`

**Interfaces:**
- Consumes: all `Mix.Tasks.Surreal.GenContextBuilder` functions from Tasks 1–4;
  `Mix.Tasks.Surreal.MigrationTaskHelpers.repo_path/1`.
- Produces: the `mix surreal.gen.context` task. No callers downstream.

**Reference — existing patterns to copy:**
- Igniter guard + fallback: `lib/mix/tasks/hgs_surrealdb_sdk.install.ex`.
- `Igniter.Test` usage (`test_project/0`, `assert_creates/3`): `test/mix/tasks/hgs_surrealdb_sdk_install_test.exs`. `test_project()` uses app `:test`, module prefix `Test`.
- Rest positional args: `positional: [..., fields: [rest: true]]`, read via `igniter.args.positional.fields` (see `deps/igniter/lib/mix/tasks/igniter.add.ex`).

- [ ] **Step 1: Write the failing test**

Create `test/mix/tasks/surreal_gen_context_test.exs`:

```elixir
defmodule Mix.Tasks.Surreal.Gen.ContextTest do
  use ExUnit.Case, async: true
  import Igniter.Test

  test "generates the Zoi schema module" do
    test_project()
    |> Igniter.compose_task("surreal.gen.context", [
      "Accounts",
      "User",
      "name:string",
      "email:string",
      "age:int?"
    ])
    |> assert_creates("lib/test/accounts/user.ex", """
    defmodule Test.Accounts.User do
      @moduledoc \"\"\"
      SurrealDB schema for the `user` table.
      \"\"\"
      use SurrealDB.Schema

      table "user"

      schema do
        Zoi.object(%{
          id: Zoi.string() |> Zoi.optional(),
          name: Zoi.string(),
          email: Zoi.string(),
          age: Zoi.integer() |> Zoi.optional()
        })
      end
    end
    """)
  end

  test "generates the context module with delegating CRUD" do
    test_project()
    |> Igniter.compose_task("surreal.gen.context", ["Accounts", "User", "name:string"])
    |> assert_creates("lib/test/accounts.ex", """
    defmodule Test.Accounts do
      @moduledoc \"\"\"
      The Accounts context.
      \"\"\"
      alias Test.Accounts.User
      alias Test.SurrealStore

      def list_users(filters \\\\ %{}), do: SurrealStore.all(User, filters)
      def get_user(id), do: SurrealStore.get(User, id)
      def create_user(attrs), do: SurrealStore.create(User, attrs)
      def update_user(id, attrs), do: SurrealStore.update(User, id, attrs)
      def delete_user(id), do: SurrealStore.delete(User, id)
    end
    """)
  end

  test "creates the migration at a deterministic path with --migration-timestamp" do
    test_project()
    |> Igniter.compose_task("surreal.gen.context", [
      "Accounts",
      "User",
      "name:string",
      "--migration-timestamp",
      "20260627000000"
    ])
    |> assert_creates(
      "priv/surreal_repo/migrations/20260627000000_create_user.surql",
      """
      -- create_user

      -- migrate:up
      DEFINE TABLE user TYPE NORMAL SCHEMAFULL PERMISSIONS NONE;
      DEFINE FIELD name ON user TYPE STRING;

      -- migrate:down
      REMOVE TABLE user;
      """
    )
  end

  test "honors --table and --store overrides" do
    test_project()
    |> Igniter.compose_task("surreal.gen.context", [
      "Accounts",
      "Person",
      "name:string",
      "--table",
      "people_record",
      "--store",
      "Test.OtherStore",
      "--migration-timestamp",
      "20260627000000"
    ])
    |> assert_creates(
      "priv/surreal_repo/migrations/20260627000000_create_people_record.surql"
    )
  end
end
```

NOTE: If `assert_creates/3` requires the migration body to match exactly and the
formatter/trailing-newline differs, switch that assertion to the 2-arg
`assert_creates(igniter, path)` form (existence only) — the body is already covered by
the Task 4 builder unit test. Verify the exact heredoc matches by running the test; adjust
whitespace to match Igniter's output if needed.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/mix/tasks/surreal_gen_context_test.exs`
Expected: FAIL — task `surreal.gen.context` not found.

- [ ] **Step 3: Write minimal implementation**

Create `lib/mix/tasks/surreal.gen.context.ex`:

```elixir
if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Surreal.Gen.Context do
    @shortdoc "Generates a SurrealDB context, Zoi schema, and migration"
    @moduledoc """
    #{@shortdoc}

    Generates a context module, a `SurrealDB.Schema` (Zoi) module nested under it, and a
    timestamped `.surql` migration in the host application.

        $ mix surreal.gen.context Accounts User name:string email:string age:int
        $ mix surreal.gen.context Accounts User "created_at:datetime|readonly|default=time::now()"

    ## Field syntax

        name:type[?][|modifier]...

    `?` marks the field optional (`OPTION<TYPE>` + `Zoi.optional()`). Modifiers are
    `|`-delimited and emitted into the migration only: `readonly`, `default=<surql>`,
    `assert=<surql>`, `value=<surql>`.

    ## Options

      * `--table`     - SurrealDB table name (default: snake_case of the schema)
      * `--store`     - store module the context delegates to (default: `<App>.SurrealStore`)
      * `--plural`    - plural used in function names (default: naive pluralization)
      * `--repo-path` - migrations root (default: resolved from store config / `priv/surreal_repo`)
    """

    use Igniter.Mix.Task

    alias Mix.Tasks.Surreal.GenContextBuilder, as: Builder
    alias Mix.Tasks.Surreal.MigrationTaskHelpers, as: Helpers

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :hgs_surrealdb_sdk,
        example: "mix surreal.gen.context Accounts User name:string email:string",
        positional: [:context, :schema, fields: [rest: true]],
        schema: [
          table: :string,
          store: :string,
          plural: :string,
          repo_path: :string,
          migration_timestamp: :string
        ]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      %{context: context_arg, schema: schema_arg, fields: field_specs} = igniter.args.positional
      opts = igniter.args.options

      prefix = Igniter.Project.Module.module_name_prefix(igniter)
      context_mod = Module.concat(prefix, context_arg)
      schema_mod = Module.concat([prefix, context_arg, schema_arg])
      store_mod = resolve_store(opts, prefix)

      fields = Builder.parse_fields!(field_specs)
      table = opts[:table] || Builder.table_name(schema_arg)
      plural = opts[:plural] || Builder.pluralize(table)
      migration_name = "create_#{table}"
      timestamp = opts[:migration_timestamp] || Builder.timestamp()

      migration_path =
        Helpers.repo_path(Enum.to_list(opts))
        |> Path.join("migrations")
        |> Path.join(Builder.migration_filename(timestamp, migration_name))

      igniter
      |> Igniter.Project.Module.create_module(schema_mod, Builder.schema_module_body(table, fields))
      |> Igniter.Project.Module.create_module(
        context_mod,
        Builder.context_module_body(context_mod, schema_mod, store_mod, table, plural)
      )
      |> Igniter.create_new_file(migration_path, Builder.migration_body(table, migration_name, fields))
      |> Igniter.add_notice("""
      Generated #{inspect(context_mod)}, #{inspect(schema_mod)}, and
      #{migration_path}.

      Apply the migration with `mix surreal.migrate`.
      """)
    end

    defp resolve_store(opts, prefix) do
      case opts[:store] do
        nil -> Module.concat(prefix, SurrealStore)
        store when is_binary(store) -> Module.concat([store])
      end
    end
  end
else
  defmodule Mix.Tasks.Surreal.Gen.Context do
    @shortdoc "Generates a SurrealDB context, Zoi schema, and migration"
    @moduledoc @shortdoc

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'surreal.gen.context' requires igniter, which is an optional dependency
      that is not installed in this project.

      Install it through igniter's own installer:

          mix igniter.install hgs_surrealdb_sdk

      Or add igniter to your deps and re-run:

          {:igniter, "~> 0.5", only: [:dev]}
      """)

      exit({:shutdown, 1})
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/mix/tasks/surreal_gen_context_test.exs`
Expected: PASS. If a migration-body `assert_creates/3` fails purely on whitespace,
apply the NOTE in Step 1 (switch to existence-only `assert_creates/2`) and re-run.

- [ ] **Step 5: Commit**

```bash
git add lib/mix/tasks/surreal.gen.context.ex test/mix/tasks/surreal_gen_context_test.exs
git commit -m "feat: add mix surreal.gen.context Igniter task"
```

---

## Task 6: Docs, full-suite verification, and end-to-end check

**Files:**
- Modify: `README.md` (if it documents the other `surreal.*` tasks — check first)
- No new code.

**Interfaces:** none.

- [ ] **Step 1: Document the task**

Check whether `README.md` (or `docs/`) lists the `surreal.*` mix tasks (e.g. grep for
`surreal.gen.migration`). If it does, add a `surreal.gen.context` entry following the
exact same format, including the example:

```
mix surreal.gen.context Accounts User name:string email:string "created_at:datetime|readonly|default=time::now()"
```

If no such task listing exists, skip this step (do not invent a new docs section).

- [ ] **Step 2: Run the full SDK test suite**

Run: `mix test`
Expected: PASS — all pre-existing tests plus the new builder and task tests green.
Do NOT proceed until green. If any pre-existing test fails, investigate before
continuing (use systematic-debugging).

- [ ] **Step 3: Compile check (no warnings)**

Run: `mix compile --warnings-as-errors`
Expected: clean compile.

- [ ] **Step 4: End-to-end in the consuming app (`test_igniter`)**

This proves the generator lands files correctly in a real host app. The host app at
`../../tmp/test_igniter` depends on the SDK. To exercise the working branch, the host's
`deps/hgs_surrealdb_sdk` must reflect this branch — confirm with the user how they want
the dep pointed (local `path:` override vs. updating the git checkout) BEFORE running, to
avoid surprising dependency edits. Once pointed at this branch, from the `test_igniter`
directory run:

```bash
mix surreal.gen.context Catalog Product name:string price:decimal "in_stock:bool|default=true"
```

Verify:
- `lib/test_igniter/catalog/product.ex` exists with `use SurrealDB.Schema`, `table "product"`, and a Zoi object containing `id`, `name`, `price`, `in_stock`.
- `lib/test_igniter/catalog.ex` exists with `list_products/1`, `get_product/1`, `create_product/1`, `update_product/2`, `delete_product/1` delegating to `TestIgniter.SurrealStore`.
- `priv/surreal_repo/migrations/<ts>_create_product.surql` exists with `DEFINE TABLE product …`, a `DEFINE FIELD in_stock ON product TYPE BOOL DEFAULT true;` line, and the `-- migrate:down` `REMOVE TABLE product;`.
- From `test_igniter`: `mix compile` is clean.

Report the three generated file contents to the user. Do NOT run `mix surreal.migrate`
against any real database — only a scratch/dev namespace/database, and only if the user
asks (per the surreal task scope-safety practice).

- [ ] **Step 5: Commit any doc change**

```bash
git add README.md
git commit -m "docs: document mix surreal.gen.context task"
```

(Skip if Step 1 made no changes.)

---

## Self-Review

**Spec coverage:**
- §3 command interface → Task 5 (`info/2` positional + schema, `--table/--store/--plural/--repo-path`). ✅
- §4 field grammar (first-`:` split, `?`, `|`-modifiers, `record:<table>`) → Tasks 1–2. ✅
- §4.1 type map → Task 1 `@type_map` + record special-case. ✅
- §4 modifier ordering (READONLY/DEFAULT/VALUE/ASSERT) → Task 2 `modifier_clauses/1`. ✅
- §5.1 schema module (id-first, optional piping) → Task 4 + Task 5 integration test. ✅
- §5.2 migration (`DEFINE TABLE … SCHEMAFULL`, no id field line, up/down) → Task 4 + Task 5. ✅
- §5.3 context (named delegations, store alias, plural/singular naming) → Task 4 + Task 5. ✅
- §6 architecture (pure builder + guarded Igniter task) → Tasks 1–5. ✅
- §7 error handling (fail-fast parse, raises with supported lists) → Task 1 (`parse_fields!` runs before any create in Task 5's `igniter/1`). ✅
- §8 testing (builder unit tests + Igniter integration test) → Tasks 1–5 + Task 6 full suite. ✅
- §9 end-to-end in test_igniter → Task 6 Step 4. ✅
- §10 out-of-scope (no test-file gen, no Zoi translation of asserts) → respected (no tasks add these). ✅
- §11 open questions resolved during planning: store arities confirmed (`store.ex`), rest-positional API confirmed (`igniter.add`), timestamp put in builder. ✅

**Placeholder scan:** No TBD/TODO; every code step contains complete code. The Task 5
Step-1 NOTE is a concrete conditional fallback (existence-only assertion), not a
placeholder.

**Type consistency:** `Field` fields (`name`, `surreal_type`, `zoi_base`, `optional?`,
`modifiers`) used identically across Tasks 1–4. `zoi_expr/1`, `define_field_line/2`,
`migration_body/3`, `schema_module_body/2`, `context_module_body/5` signatures match
between their producing task and Task 5's consumption. Store calls (`all/2`, `get/2`,
`create/2`, `update/3`, `delete/2`) match `lib/surreal_db/store.ex`.
