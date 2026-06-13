# SurrealDB.Schema + SurrealDB.Repo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `SurrealDB.Schema` (Zoi-backed, table-bound schema modules that hydrate into structs) and a `SurrealDB.Repo` (friendly, parameterized persistence functions) layer over the existing `SurrealDB.query/3` API.

**Architecture:** `SurrealDB.Schema` is a `use`-able macro module: `table/1` records the table name, `schema do ... end` captures a `Zoi.object(%{...})` and derives a struct from the literal field keys (compile-time AST extraction — no Zoi-internals introspection). Validation/hydration/dump delegate to runtime helpers that wrap Zoi errors in `SurrealDB.Schema.ValidationError`. `SurrealDB.Repo` builds parameterized SurrealQL (`$id`, `type::table($table)`, `$attrs`) plus a vars map and runs them through `SurrealDB.query/3`, then hydrates result records into schema structs. `SurrealDB.Repo.FilterBuilder` turns a simple equality-filter map into a parameterized `WHERE` clause.

**Tech Stack:** Elixir, [Zoi](https://hexdocs.pm/zoi/0.7.4) `~> 0.7` (resolves to 0.7.4), the existing `SurrealDB` SDK (`Req`-based HTTP transport), ExUnit.

**Source spec:** `artifacts/schema_and_repo.md`. Decisions locked during brainstorming: (1) modules live under the existing `SurrealDB.*` namespace (the `HgsSurrealdbSdk.*` names in the spec are a copy error; file paths in the spec already say `lib/surreal_db/...`); (2) scope is the **initial** API + **simple equality filters** only — the optional follow-up API (`find_or_create`, `find_and_update`, `upsert`) and advanced filter operators (`gte`/`like`/`in`/`limit`/`order_by`) are explicitly deferred; (3) tests stub the transport with the existing `client_with_adapter` Req-adapter pattern (no live DB, no Mox).

---

## Codebase facts the implementer must know

These are established by the existing code — do not re-derive, do not change them.

- **Public query entrypoint:** `SurrealDB.query(client, surql, vars)` returns `{:ok, %SurrealDB.QueryResult{}} | {:error, %SurrealDB.Error{}}`.
- **`%SurrealDB.QueryResult{}`** has `results: [term()]` — one element per SurrealQL statement. For a single-statement query, `results` is a 1-element list whose element is the statement's result (a list of record maps for `SELECT`/`CREATE`/`UPDATE`/`DELETE ... RETURN`).
- **Record maps from the DB have STRING keys** (e.g. `%{"id" => "user:abc", "name" => "Jane"}`).
- **`%SurrealDB.Error{}`** is `defexception [:type, :message, :status, :code, details: %{}, raw: nil]`.
- **Variable encoding (HTTP transport):** `SurrealDB.query/3` sends the SurrealQL to the `/sql` endpoint after `SurrealDB.Variables.apply/2` substitutes each `$name` with its **JSON-encoded** value: strings become quoted (`"jane@example.com"`), numbers/booleans become literals (`42`, `true`), maps/lists become JSON objects/arrays. So `SELECT * FROM type::table($table)` with `%{table: "user"}` is transmitted as `SELECT * FROM type::table("user")`. Variable names must be simple identifiers (`[A-Za-z_][A-Za-z0-9_]*`); keys may be atoms or strings.
- **Test harness pattern** (copied verbatim from `test/surreal_db/crud_test.exs`): build a `%SurrealDB.Client{}` with `request_options: [adapter: fn]`. The adapter receives the `Req` request (with `.body` already containing the post-`Variables.apply` SurrealQL string) and returns `{request, %Req.Response{}}`. A success body is a JSON array like `[{"status":"OK","result":[ ...records... ]}]`.

## Parameterization vs. record IDs — known POC caveat (read once)

The spec's `get` SurrealQL is `SELECT * FROM $id` with `%{id: "user:abc"}`. Because `Variables.apply/2` JSON-encodes the value, the wire form is `SELECT * FROM "user:abc"` (a quoted string, not a bare record id). Whether real SurrealDB resolves a quoted string to a record is **not exercised by this plan** — all tests stub the transport, so they are deterministic regardless. We implement the spec's SurrealQL exactly. A follow-up may switch `get`/`update`/`delete` to `type::thing($tb, $id)` for correct record resolution; that is out of scope here. Note this in the `Repo` moduledoc.

---

## File structure & parallelization map

Each task is sized for one Haiku agent and **owns a disjoint set of files** so tasks in the same wave never edit the same file.

| Task | Owns (create unless noted) | Depends on |
|------|----------------------------|------------|
| **T1** Add Zoi dependency | `mix.exs` (modify), `mix.lock` (generated) | — |
| **T2** ValidationError | `lib/surreal_db/schema/validation_error.ex`, `test/surreal_db/schema/validation_error_test.exs` | — |
| **T3** FilterBuilder | `lib/surreal_db/repo/filter_builder.ex`, `test/surreal_db/repo/filter_builder_test.exs` | — |
| **T4** Schema | `lib/surreal_db/schema.ex`, `test/surreal_db/schema_test.exs` | T1, T2 |
| **T5** Repo | `lib/surreal_db/repo.ex`, `test/surreal_db/repo_test.exs` | T1, T2, T3, T4 |
| **T6** Integration + verification | `test/surreal_db/repo/integration_test.exs` | T1–T5 |

**Execution waves (maximize parallelism):**

- **Wave 1 — fully parallel:** T1, T2, T3 (no interdependencies; disjoint files).
- **Wave 2:** T4 (needs Zoi compiled + ValidationError).
- **Wave 3:** T5 (needs Schema, FilterBuilder, ValidationError).
- **Wave 4:** T6 (end-to-end example + full-suite verification).

Each task is independently committable and leaves the project compiling. T4 and T5 reference modules built in earlier waves; the **interface contracts** below are exact so a later-wave agent never needs to read an earlier agent's internals.

### Interface contracts (the only cross-task surface)

```elixir
# T2 — SurrealDB.Schema.ValidationError
%SurrealDB.Schema.ValidationError{message: String.t(), errors: [%{path: list(), message: String.t()}]}
SurrealDB.Schema.ValidationError.from_zoi(zoi_errors :: list()) :: %SurrealDB.Schema.ValidationError{}

# T3 — SurrealDB.Repo.FilterBuilder
SurrealDB.Repo.FilterBuilder.build(filters :: map()) ::
  {:ok, {where_clause :: String.t(), vars :: map()}} | {:error, %SurrealDB.Error{}}
# build(%{})                          -> {:ok, {"", %{}}}
# build(%{email: "x"})               -> {:ok, {"WHERE email = $email", %{email: "x"}}}
# build(%{email: "x", status: "y"})  -> {:ok, {"WHERE email = $email AND status = $status", %{email: "x", status: "y"}}}  (keys alphabetized)

# T4 — a schema module created with `use SurrealDB.Schema` exposes:
Module.__table__() :: String.t()
Module.__schema__() :: Zoi.Type.t()
Module.validate(params :: map()) :: {:ok, map()} | {:error, %SurrealDB.Schema.ValidationError{}}
Module.hydrate(record :: map()) :: {:ok, struct()} | {:error, %SurrealDB.Schema.ValidationError{}}
Module.dump(struct()) :: {:ok, map()} | {:error, %SurrealDB.Schema.ValidationError{}}
```

---

## Task 1: Add Zoi dependency

**Files:**
- Modify: `mix.exs` (the `deps/0` list)
- Generated: `mix.lock`

- [ ] **Step 1: Add the dep**

In `mix.exs`, add `{:zoi, "~> 0.7"}` to the `deps/0` list (place it with the runtime deps, next to `{:req, "~> 0.5"}`). Result:

```elixir
defp deps do
  [
    {:req, "~> 0.5"},
    {:zoi, "~> 0.7"},
    {:jason, "~> 1.4"},
    {:websockex, "~> 0.5.1"},
    {:bandit, "~> 1.0", only: :dev},
    {:tidewave, "~> 0.5", only: [:dev]}
  ]
end
```

- [ ] **Step 2: Fetch and confirm the version**

Run: `mix deps.get`
Expected: output includes a line resolving `zoi 0.7.x` (e.g. `zoi 0.7.4`), and `mix.lock` now contains a `"zoi":` entry.

- [ ] **Step 3: Confirm it compiles**

Run: `mix compile`
Expected: compiles with no errors (warnings about the not-yet-existing Schema/Repo modules are fine — they don't exist yet).

- [ ] **Step 4: Commit**

```bash
git add mix.exs mix.lock
git commit -m "build: add zoi dependency for schema validation"
```

---

## Task 2: SurrealDB.Schema.ValidationError

Wraps a list of Zoi validation errors into one SDK exception without leaking `%Zoi.Error{}` internals. This module has **no dependency on Zoi** — `from_zoi/1` accepts any list of items that respond to `:path` and `:message` map access, so it is fully testable in isolation.

**Files:**
- Create: `lib/surreal_db/schema/validation_error.ex`
- Test: `test/surreal_db/schema/validation_error_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/surreal_db/schema/validation_error_test.exs`:

```elixir
defmodule SurrealDB.Schema.ValidationErrorTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Schema.ValidationError

  test "from_zoi/1 normalizes a list of errors into plain maps" do
    error =
      ValidationError.from_zoi([
        %{path: [:email], message: "invalid email format"},
        %{path: [:age], message: "too small: must be at least 0"}
      ])

    assert %ValidationError{errors: errors} = error

    assert errors == [
             %{path: [:email], message: "invalid email format"},
             %{path: [:age], message: "too small: must be at least 0"}
           ]
  end

  test "from_zoi/1 builds a readable summary message" do
    error = ValidationError.from_zoi([%{path: [:email], message: "invalid email format"}])

    assert error.message =~ "email"
    assert error.message =~ "invalid email format"
  end

  test "from_zoi/1 handles an empty path as root" do
    error = ValidationError.from_zoi([%{path: [], message: "is invalid"}])

    assert error.errors == [%{path: [], message: "is invalid"}]
    assert error.message =~ "is invalid"
  end

  test "is a raisable exception" do
    error = ValidationError.from_zoi([%{path: [:name], message: "is required"}])
    assert is_binary(Exception.message(error))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/surreal_db/schema/validation_error_test.exs`
Expected: FAIL with `module SurrealDB.Schema.ValidationError is not available`.

- [ ] **Step 3: Write the implementation**

Create `lib/surreal_db/schema/validation_error.ex`:

```elixir
defmodule SurrealDB.Schema.ValidationError do
  @moduledoc """
  Raised/returned when data fails to validate against a `SurrealDB.Schema`.

  Wraps the underlying Zoi validation errors as a flat list of plain maps so
  callers never have to pattern-match on Zoi internals.
  """

  @type normalized_error :: %{path: list(), message: String.t()}
  @type t :: %__MODULE__{message: String.t(), errors: [normalized_error()]}

  defexception message: "validation failed", errors: []

  @doc """
  Build a `ValidationError` from a list of Zoi errors (`%Zoi.Error{}` structs)
  or any maps exposing `:path` and `:message`.
  """
  @spec from_zoi(list()) :: t()
  def from_zoi(errors) when is_list(errors) do
    normalized =
      Enum.map(errors, fn error ->
        %{path: Map.get(error, :path, []) || [], message: Map.get(error, :message)}
      end)

    %__MODULE__{errors: normalized, message: build_message(normalized)}
  end

  defp build_message([]), do: "validation failed"

  defp build_message(normalized) do
    normalized
    |> Enum.map(fn %{path: path, message: message} -> "#{format_path(path)}: #{message}" end)
    |> Enum.join("; ")
  end

  defp format_path([]), do: "(root)"
  defp format_path(path), do: Enum.map_join(path, ".", &to_string/1)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/surreal_db/schema/validation_error_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/surreal_db/schema/validation_error.ex test/surreal_db/schema/validation_error_test.exs
git commit -m "feat: add SurrealDB.Schema.ValidationError"
```

---

## Task 3: SurrealDB.Repo.FilterBuilder

Pure module: turns a simple equality-filter map into a parameterized `WHERE` clause and a vars map. Keys are **alphabetized** so output is deterministic. Keys must be simple identifiers (they are interpolated as field names — values are always parameterized, never interpolated). No dependency on anything but `SurrealDB.Error`.

**Files:**
- Create: `lib/surreal_db/repo/filter_builder.ex`
- Test: `test/surreal_db/repo/filter_builder_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/surreal_db/repo/filter_builder_test.exs`:

```elixir
defmodule SurrealDB.Repo.FilterBuilderTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Error
  alias SurrealDB.Repo.FilterBuilder

  test "empty filters produce no clause" do
    assert {:ok, {"", %{}}} = FilterBuilder.build(%{})
  end

  test "single equality filter is parameterized" do
    assert {:ok, {"WHERE email = $email", %{email: "jane@example.com"}}} =
             FilterBuilder.build(%{email: "jane@example.com"})
  end

  test "multiple filters are alphabetized and AND-joined" do
    assert {:ok, {"WHERE email = $email AND status = $status", vars}} =
             FilterBuilder.build(%{status: "active", email: "jane@example.com"})

    assert vars == %{email: "jane@example.com", status: "active"}
  end

  test "string keys are accepted and preserved in vars" do
    assert {:ok, {"WHERE email = $email", %{"email" => "x"}}} =
             FilterBuilder.build(%{"email" => "x"})
  end

  test "invalid field names are rejected, not interpolated" do
    assert {:error, %Error{type: :invalid_filter}} = FilterBuilder.build(%{"name; DROP" => 1})
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/surreal_db/repo/filter_builder_test.exs`
Expected: FAIL with `module SurrealDB.Repo.FilterBuilder is not available`.

- [ ] **Step 3: Write the implementation**

Create `lib/surreal_db/repo/filter_builder.ex`:

```elixir
defmodule SurrealDB.Repo.FilterBuilder do
  @moduledoc """
  Builds a parameterized SurrealQL `WHERE` clause from a simple equality-filter
  map. POC scope: equality only. Values are always parameterized (`$field`);
  field names are validated as simple identifiers and never carry user values.
  """

  alias SurrealDB.Error

  @identifier ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  @spec build(map()) :: {:ok, {String.t(), map()}} | {:error, Error.t()}
  def build(filters) when is_map(filters) do
    filters
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.reduce_while({[], %{}}, fn {key, value}, {clauses, vars} ->
      case validate_key(key) do
        {:ok, name} ->
          {:cont, {[~s(#{name} = $#{name}) | clauses], Map.put(vars, key, value)}}

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
    |> finalize()
  end

  defp finalize({:error, %Error{} = error}), do: {:error, error}
  defp finalize({[], _vars}), do: {:ok, {"", %{}}}

  defp finalize({clauses, vars}) do
    clause = "WHERE " <> (clauses |> Enum.reverse() |> Enum.join(" AND "))
    {:ok, {clause, vars}}
  end

  defp validate_key(key) do
    name = to_string(key)

    if Regex.match?(@identifier, name) do
      {:ok, name}
    else
      {:error,
       %Error{
         type: :invalid_filter,
         message: "filter field names must be simple identifiers",
         details: %{field: key}
       }}
    end
  end
end
```

> Note: `Enum.sort_by` alphabetizes, and we prepend then `Enum.reverse()` to keep the clause order matching the sorted (alphabetical) order while building the list cheaply. `vars` keeps the original key (atom or string); `SurrealDB.Variables.apply/2` normalizes either form to the `$name` in the clause.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/surreal_db/repo/filter_builder_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/surreal_db/repo/filter_builder.ex test/surreal_db/repo/filter_builder_test.exs
git commit -m "feat: add SurrealDB.Repo.FilterBuilder for equality filters"
```

---

## Task 4: SurrealDB.Schema

Depends on **T1 (Zoi)** and **T2 (ValidationError)**. The `use SurrealDB.Schema` macro provides `table/1` and `schema do ... end`. It derives a struct from the literal field keys of the `Zoi.object(%{...})` map (compile-time AST walk — see `__extract_field_keys__/1`). Validation/hydration/dump delegate to runtime helpers. `Zoi.parse/3` is called with `coerce: true` so DB records with **string keys** validate and hydrate correctly (Zoi coerces string keys to atoms and strips unknown keys).

**Files:**
- Create: `lib/surreal_db/schema.ex`
- Test: `test/surreal_db/schema_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/surreal_db/schema_test.exs`:

```elixir
defmodule SurrealDB.SchemaTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Schema.ValidationError

  defmodule User do
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

  test "__table__/0 returns the declared table" do
    assert User.__table__() == "user"
  end

  test "the schema module defines a struct with the declared fields" do
    user = %User{}
    assert Map.keys(Map.from_struct(user)) |> Enum.sort() == [:age, :email, :id, :name]
  end

  test "validate/1 returns the validated map for valid params" do
    assert {:ok, %{name: "Jane", email: "jane@example.com"}} =
             User.validate(%{name: "Jane", email: "jane@example.com"})
  end

  test "validate/1 returns a ValidationError for invalid params" do
    assert {:error, %ValidationError{errors: errors}} = User.validate(%{name: "Jane"})
    assert Enum.any?(errors, fn %{path: path} -> path == [:email] end)
  end

  test "hydrate/1 builds a struct from a DB record with string keys" do
    record = %{"id" => "user:abc", "name" => "Jane", "email" => "jane@example.com"}
    assert {:ok, %User{id: "user:abc", name: "Jane", email: "jane@example.com"}} =
             User.hydrate(record)
  end

  test "hydrate/1 returns a ValidationError for an invalid record" do
    assert {:error, %ValidationError{}} = User.hydrate(%{"name" => "Jane"})
  end

  test "dump/1 turns a struct into a validated map, dropping nils" do
    user = %User{name: "Jane", email: "jane@example.com"}
    assert {:ok, dumped} = User.dump(user)
    assert dumped == %{name: "Jane", email: "jane@example.com"}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/surreal_db/schema_test.exs`
Expected: FAIL with `module SurrealDB.Schema is not available` (compile error on `use SurrealDB.Schema`).

- [ ] **Step 3: Write the implementation**

Create `lib/surreal_db/schema.ex`:

```elixir
defmodule SurrealDB.Schema do
  @moduledoc """
  Defines a table-backed schema using [Zoi](https://hexdocs.pm/zoi).

      defmodule MyApp.User do
        use SurrealDB.Schema

        table "user"

        schema do
          Zoi.object(%{
            id: Zoi.string() |> Zoi.optional(),
            name: Zoi.string(),
            email: Zoi.string()
          })
        end
      end

  A schema module gets a struct (one field per key of the `Zoi.object/1` map)
  plus `__table__/0`, `__schema__/0`, `validate/1`, `hydrate/1`, and `dump/1`.

  The `schema do ... end` block must contain a `Zoi.object(%{...})` with a
  literal field map — the struct fields are read from that map at compile time.
  """

  alias SurrealDB.Schema.ValidationError

  defmacro __using__(_opts) do
    quote do
      import SurrealDB.Schema, only: [table: 1, schema: 1]
      @before_compile SurrealDB.Schema
    end
  end

  @doc "Declares the SurrealDB table name backing this schema."
  defmacro table(name) do
    quote do
      @surreal_table unquote(name)
    end
  end

  @doc "Captures the Zoi schema and derives the struct from its field keys."
  defmacro schema(do: block) do
    field_keys = __extract_field_keys__(block)

    quote do
      defstruct unquote(field_keys)

      @doc false
      def __schema__, do: unquote(block)
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc false
      def __table__, do: @surreal_table

      @doc false
      def validate(params), do: SurrealDB.Schema.__validate__(__schema__(), params)

      @doc false
      def hydrate(record),
        do: SurrealDB.Schema.__hydrate__(__MODULE__, __schema__(), record)

      @doc false
      def dump(data), do: SurrealDB.Schema.__dump__(__schema__(), data)
    end
  end

  @doc false
  # Walks the AST of the `schema do ... end` block and returns the keys of the
  # first map literal it finds (the `Zoi.object(%{...})` field map).
  def __extract_field_keys__(ast) do
    {_ast, keys} =
      Macro.prewalk(ast, nil, fn
        {:%{}, _meta, pairs} = node, nil when is_list(pairs) ->
          {node, Enum.map(pairs, fn {key, _value} -> key end)}

        node, acc ->
          {node, acc}
      end)

    keys || raise ArgumentError, "schema/1 block must contain a Zoi.object(%{...}) literal"
  end

  @doc false
  def __validate__(schema, params) do
    case Zoi.parse(schema, params, coerce: true) do
      {:ok, value} -> {:ok, value}
      {:error, errors} -> {:error, ValidationError.from_zoi(errors)}
    end
  end

  @doc false
  def __hydrate__(module, schema, record) do
    with {:ok, value} <- __validate__(schema, record) do
      {:ok, struct(module, value)}
    end
  end

  @doc false
  def __dump__(schema, %_{} = data) do
    map =
      data
      |> Map.from_struct()
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    __validate__(schema, map)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/surreal_db/schema_test.exs`
Expected: PASS (7 tests).

> If `validate/1` unexpectedly fails on valid params, confirm `coerce: true` is passed to `Zoi.parse/3` — without it, string-keyed records won't match atom-keyed schema fields.

- [ ] **Step 5: Commit**

```bash
git add lib/surreal_db/schema.ex test/surreal_db/schema_test.exs
git commit -m "feat: add SurrealDB.Schema with Zoi-backed struct hydration"
```

---

## Task 5: SurrealDB.Repo

Depends on **T1 (Zoi)**, **T2 (ValidationError)**, **T3 (FilterBuilder)**, **T4 (Schema)**. Builds parameterized SurrealQL, runs it through `SurrealDB.query/3`, and hydrates result records into schema structs.

**Generated SurrealQL (exact):**

| Function | SurrealQL | vars |
|----------|-----------|------|
| `get` | `SELECT * FROM $id` | `%{id: id}` |
| `all` | `SELECT * FROM type::table($table)` + optional ` WHERE ...` | `%{table: t}` ∪ filter vars |
| `find` | `SELECT * FROM type::table($table)` + optional ` WHERE ...` + ` LIMIT 1` | `%{table: t}` ∪ filter vars |
| `create` | `CREATE type::table($table) CONTENT $attrs` | `%{table: t, attrs: attrs}` |
| `update` | `UPDATE $id MERGE $attrs` | `%{id: id, attrs: attrs}` |
| `delete` | `DELETE $id RETURN BEFORE` | `%{id: id}` |
| `query` | caller-supplied | caller-supplied |

**Result handling:** take the first statement result from `%QueryResult{results: [first | _]}`. Normalize it to a list of record maps (`nil → []`, a single map → `[map]`, a list stays). `get`/`find`/`update`/`delete` hydrate and return the first record (`{:ok, struct}` or `{:ok, nil}` when empty). `all`/`query` hydrate every record (`{:ok, [struct]}`). `create` validates `attrs` against the schema first, then returns the created struct.

**Files:**
- Create: `lib/surreal_db/repo.ex`
- Test: `test/surreal_db/repo_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/surreal_db/repo_test.exs`:

```elixir
defmodule SurrealDB.RepoTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Client
  alias SurrealDB.Repo
  alias SurrealDB.Schema.ValidationError

  defmodule User do
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

  # ---- harness (mirrors test/surreal_db/crud_test.exs) ----

  defp client_with_adapter(adapter) do
    %Client{
      endpoint: "http://localhost:8000",
      namespace: "test",
      database: "app",
      auth: {:basic, %{username: "root", password: "root"}},
      request_options: [adapter: adapter]
    }
  end

  defp records_response(request, records) do
    body = Jason.encode!([%{"status" => "OK", "result" => records}])
    {request, Req.Response.new(status: 200, body: body)}
  end

  defp assert_json_tail(body, prefix, expected) do
    json = String.replace_prefix(body, prefix, "")
    assert Jason.decode!(json) == expected
  end

  @jane %{"id" => "user:abc", "name" => "Jane", "email" => "jane@example.com"}

  # ---- get ----

  test "get/3 selects by id and hydrates a struct" do
    client =
      client_with_adapter(fn request ->
        assert request.body == ~s(SELECT * FROM "user:abc")
        records_response(request, [@jane])
      end)

    assert {:ok, %User{id: "user:abc", name: "Jane", email: "jane@example.com"}} =
             Repo.get(client, User, "user:abc")
  end

  test "get/3 returns {:ok, nil} when nothing is found" do
    client =
      client_with_adapter(fn request -> records_response(request, []) end)

    assert {:ok, nil} = Repo.get(client, User, "user:zzz")
  end

  # ---- all ----

  test "all/2 selects the whole table and hydrates a list" do
    client =
      client_with_adapter(fn request ->
        assert request.body == ~s(SELECT * FROM type::table("user"))
        records_response(request, [@jane])
      end)

    assert {:ok, [%User{name: "Jane"}]} = Repo.all(client, User)
  end

  test "all/3 applies equality filters" do
    client =
      client_with_adapter(fn request ->
        assert request.body ==
                 ~s(SELECT * FROM type::table("user") WHERE email = "jane@example.com")

        records_response(request, [@jane])
      end)

    assert {:ok, [%User{}]} = Repo.all(client, User, %{email: "jane@example.com"})
  end

  # ---- find ----

  test "find/3 adds LIMIT 1 and returns a single struct" do
    client =
      client_with_adapter(fn request ->
        assert request.body ==
                 ~s(SELECT * FROM type::table("user") WHERE email = "jane@example.com" LIMIT 1)

        records_response(request, [@jane])
      end)

    assert {:ok, %User{name: "Jane"}} =
             Repo.find(client, User, %{email: "jane@example.com"})
  end

  # ---- create ----

  test "create/3 validates then issues a parameterized CREATE" do
    client =
      client_with_adapter(fn request ->
        assert String.starts_with?(request.body, ~s(CREATE type::table("user") CONTENT ))

        assert_json_tail(request.body, ~s(CREATE type::table("user") CONTENT ), %{
          "name" => "Jane",
          "email" => "jane@example.com"
        })

        records_response(request, [@jane])
      end)

    assert {:ok, %User{name: "Jane"}} =
             Repo.create(client, User, %{name: "Jane", email: "jane@example.com"})
  end

  test "create/3 returns a ValidationError without touching the network" do
    client =
      client_with_adapter(fn _request -> raise "network must not be called" end)

    assert {:error, %ValidationError{}} = Repo.create(client, User, %{name: "Jane"})
  end

  # ---- update ----

  test "update/4 issues a parameterized MERGE" do
    client =
      client_with_adapter(fn request ->
        assert String.starts_with?(request.body, ~s(UPDATE "user:abc" MERGE ))
        assert_json_tail(request.body, ~s(UPDATE "user:abc" MERGE ), %{"age" => 42})
        records_response(request, [Map.put(@jane, "age", 42)])
      end)

    assert {:ok, %User{age: 42}} = Repo.update(client, User, "user:abc", %{age: 42})
  end

  # ---- delete ----

  test "delete/3 issues DELETE ... RETURN BEFORE and returns the prior struct" do
    client =
      client_with_adapter(fn request ->
        assert request.body == ~s(DELETE "user:abc" RETURN BEFORE)
        records_response(request, [@jane])
      end)

    assert {:ok, %User{id: "user:abc"}} = Repo.delete(client, User, "user:abc")
  end

  # ---- query (raw escape hatch) ----

  test "query/4 runs raw SurrealQL and hydrates results" do
    client =
      client_with_adapter(fn request ->
        assert request.body == ~s(SELECT * FROM type::table("user"))
        records_response(request, [@jane])
      end)

    assert {:ok, [%User{name: "Jane"}]} =
             Repo.query(client, User, "SELECT * FROM type::table($table)", %{table: "user"})
  end

  # ---- error passthrough ----

  test "query errors are returned as SurrealDB.Error" do
    client =
      client_with_adapter(fn request ->
        {request, Req.Response.new(status: 401, body: ~s({"error":"unauthorized"}))}
      end)

    assert {:error, %SurrealDB.Error{}} = Repo.get(client, User, "user:abc")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/surreal_db/repo_test.exs`
Expected: FAIL with `module SurrealDB.Repo is not available`.

- [ ] **Step 3: Write the implementation**

Create `lib/surreal_db/repo.ex`:

```elixir
defmodule SurrealDB.Repo do
  @moduledoc """
  Friendly, parameterized persistence over `SurrealDB.query/3`, mapping
  `SurrealDB.Schema` modules to SurrealDB tables.

      SurrealDB.Repo.get(client, MyApp.User, "user:abc")
      SurrealDB.Repo.all(client, MyApp.User)
      SurrealDB.Repo.find(client, MyApp.User, %{email: "jane@example.com"})
      SurrealDB.Repo.create(client, MyApp.User, %{name: "Jane", email: "jane@example.com"})
      SurrealDB.Repo.update(client, MyApp.User, "user:abc", %{age: 42})
      SurrealDB.Repo.delete(client, MyApp.User, "user:abc")

  POC scope: simple equality filters only (see `SurrealDB.Repo.FilterBuilder`).
  Record ids are passed as parameters (`$id`); see the plan's "record IDs"
  caveat about quoting under the HTTP transport. Use `query/5` for raw
  SurrealQL when you need behavior outside this surface.
  """

  alias SurrealDB.{Client, Error, QueryResult}
  alias SurrealDB.Repo.FilterBuilder

  @type client :: Client.t()
  @type schema :: module()

  @spec get(client(), schema(), String.t(), keyword()) ::
          {:ok, struct() | nil} | {:error, Error.t() | SurrealDB.Schema.ValidationError.t()}
  def get(%Client{} = client, schema, id, _opts \\ []) do
    run_one(client, schema, "SELECT * FROM $id", %{id: id})
  end

  @spec all(client(), schema(), map(), keyword()) ::
          {:ok, [struct()]} | {:error, Error.t() | SurrealDB.Schema.ValidationError.t()}
  def all(%Client{} = client, schema, filters \\ %{}, _opts \\ []) do
    with {:ok, {where, filter_vars}} <- FilterBuilder.build(filters) do
      surql = "SELECT * FROM type::table($table)" <> where_suffix(where)
      vars = Map.put(filter_vars, :table, schema.__table__())
      run_many(client, schema, surql, vars)
    end
  end

  @spec find(client(), schema(), map(), keyword()) ::
          {:ok, struct() | nil} | {:error, Error.t() | SurrealDB.Schema.ValidationError.t()}
  def find(%Client{} = client, schema, filters, _opts \\ []) do
    with {:ok, {where, filter_vars}} <- FilterBuilder.build(filters) do
      surql = "SELECT * FROM type::table($table)" <> where_suffix(where) <> " LIMIT 1"
      vars = Map.put(filter_vars, :table, schema.__table__())
      run_one(client, schema, surql, vars)
    end
  end

  @spec create(client(), schema(), map(), keyword()) ::
          {:ok, struct()} | {:error, Error.t() | SurrealDB.Schema.ValidationError.t()}
  def create(%Client{} = client, schema, attrs, _opts \\ []) do
    with {:ok, validated} <- schema.validate(attrs) do
      content = validated |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
      surql = "CREATE type::table($table) CONTENT $attrs"
      vars = %{table: schema.__table__(), attrs: content}
      run_one(client, schema, surql, vars)
    end
  end

  @spec update(client(), schema(), String.t(), map(), keyword()) ::
          {:ok, struct() | nil} | {:error, Error.t() | SurrealDB.Schema.ValidationError.t()}
  def update(%Client{} = client, schema, id, attrs, _opts \\ []) do
    run_one(client, schema, "UPDATE $id MERGE $attrs", %{id: id, attrs: attrs})
  end

  @spec delete(client(), schema(), String.t(), keyword()) ::
          {:ok, struct() | nil} | {:error, Error.t() | SurrealDB.Schema.ValidationError.t()}
  def delete(%Client{} = client, schema, id, _opts \\ []) do
    run_one(client, schema, "DELETE $id RETURN BEFORE", %{id: id})
  end

  @spec query(client(), schema(), iodata(), map(), keyword()) ::
          {:ok, [struct()]} | {:error, Error.t() | SurrealDB.Schema.ValidationError.t()}
  def query(%Client{} = client, schema, surql, vars \\ %{}, _opts \\ []) do
    run_many(client, schema, surql, vars)
  end

  # ---- internals ----

  defp run_many(client, schema, surql, vars) do
    with {:ok, %QueryResult{} = result} <- SurrealDB.query(client, surql, vars) do
      hydrate_all(schema, first_records(result))
    end
  end

  defp run_one(client, schema, surql, vars) do
    with {:ok, %QueryResult{} = result} <- SurrealDB.query(client, surql, vars) do
      case first_records(result) do
        [] -> {:ok, nil}
        [record | _rest] -> schema.hydrate(record)
      end
    end
  end

  defp hydrate_all(schema, records) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
      case schema.hydrate(record) do
        {:ok, struct} -> {:cont, {:ok, [struct | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, structs} -> {:ok, Enum.reverse(structs)}
      {:error, _} = error -> error
    end
  end

  # The first statement's result, normalized to a list of record maps.
  defp first_records(%QueryResult{results: [first | _rest]}), do: normalize(first)
  defp first_records(%QueryResult{results: []}), do: []

  defp normalize(nil), do: []
  defp normalize(records) when is_list(records), do: records
  defp normalize(record) when is_map(record), do: [record]
  defp normalize(_other), do: []

  defp where_suffix(""), do: ""
  defp where_suffix(where), do: " " <> where
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/surreal_db/repo_test.exs`
Expected: PASS (12 tests).

> If a body assertion fails on `create`/`update`, remember `Variables.apply/2` JSON-encodes the map and key order is not guaranteed — that is exactly why those two use `assert_json_tail` rather than full-string equality.

- [ ] **Step 5: Commit**

```bash
git add lib/surreal_db/repo.ex test/surreal_db/repo_test.exs
git commit -m "feat: add SurrealDB.Repo persistence facade over SurrealDB.query/3"
```

---

## Task 6: Integration example + full verification

A single end-to-end test that drives a real `use SurrealDB.Schema` module through the full `Repo` surface against a stub adapter, doubling as the documented example (spec DoD #7). Then verify the whole suite and a clean warnings-as-errors compile.

**Files:**
- Create: `test/surreal_db/repo/integration_test.exs`

- [ ] **Step 1: Write the integration test**

Create `test/surreal_db/repo/integration_test.exs`:

```elixir
defmodule SurrealDB.Repo.IntegrationTest do
  @moduledoc """
  End-to-end example: declare a schema, then create/get/find/update/delete it
  through `SurrealDB.Repo` against a stubbed transport.
  """
  use ExUnit.Case, async: true

  alias SurrealDB.{Client, Repo}

  defmodule Account do
    use SurrealDB.Schema

    table "account"

    schema do
      Zoi.object(%{
        id: Zoi.string() |> Zoi.optional(),
        owner: Zoi.string(),
        balance: Zoi.integer()
      })
    end
  end

  defp client_returning(records) do
    %Client{
      endpoint: "http://localhost:8000",
      namespace: "test",
      database: "app",
      auth: {:basic, %{username: "root", password: "root"}},
      request_options: [
        adapter: fn request ->
          body = Jason.encode!([%{"status" => "OK", "result" => records}])
          {request, Req.Response.new(status: 200, body: body)}
        end
      ]
    }
  end

  test "create -> get -> find -> update -> delete round-trip hydrates structs" do
    created = %{"id" => "account:1", "owner" => "jane", "balance" => 100}

    assert {:ok, %Account{id: "account:1", owner: "jane", balance: 100}} =
             Repo.create(client_returning([created]), Account, %{owner: "jane", balance: 100})

    assert {:ok, %Account{owner: "jane"}} =
             Repo.get(client_returning([created]), Account, "account:1")

    assert {:ok, %Account{owner: "jane"}} =
             Repo.find(client_returning([created]), Account, %{owner: "jane"})

    updated = %{created | "balance" => 250}

    assert {:ok, %Account{balance: 250}} =
             Repo.update(client_returning([updated]), Account, "account:1", %{balance: 250})

    assert {:ok, %Account{id: "account:1"}} =
             Repo.delete(client_returning([created]), Account, "account:1")
  end
end
```

- [ ] **Step 2: Run the integration test**

Run: `mix test test/surreal_db/repo/integration_test.exs`
Expected: PASS (1 test).

- [ ] **Step 3: Run the full suite (spec DoD #7 — existing tests still pass)**

Run: `mix test`
Expected: all tests pass, including the pre-existing `crud_test`, `http_test`, `rpc_test`, `web_socket_test`, `config_test`, `migrations_test`.

- [ ] **Step 4: Clean compile**

Run: `mix compile --warnings-as-errors`
Expected: compiles with zero warnings.

- [ ] **Step 5: Commit**

```bash
git add test/surreal_db/repo/integration_test.exs
git commit -m "test: add end-to-end SurrealDB.Repo + Schema integration example"
```

---

## Definition of Done (mapped to spec)

| Spec DoD | Covered by |
|----------|-----------|
| 1. Schema declares `table` and `schema` | T4 (`table/1`, `schema/1`) |
| 2. Hydrate validated records into structs | T4 (`hydrate/1`), T5 (`run_one`/`hydrate_all`) |
| 3. Invalid data returns structured validation errors | T2 + T4 (`ValidationError`), T5 (`create` validates) |
| 4. `Repo.get/all/find/create/update/delete` via `SurrealDB.query/3` | T5 |
| 5. Simple equality filters parameterized, not interpolated | T3 (`FilterBuilder`), T5 |
| 6. Tests cover declaration, validation, hydration, dump, query generation, repo hydration | T2–T6 |
| 7. Existing SDK tests still pass | T6 Step 3 |

## Out of scope (deferred, per brainstorming decision)

- `find_or_create/5`, `find_and_update/5`, `upsert/5`.
- Advanced filter operators: `{:gte, _}`, `{:like, _}`, `{:in, _}`, `limit`, `order_by`.
- Switching record-id queries to `type::thing($tb, $id)` (see "record IDs" caveat).
- Partial-schema validation on `update` (currently sends the raw MERGE map unvalidated).
