# First-Class Transactions (`Store.transaction/1` + `SurrealDB.Multi`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `Ecto.Multi`-style transaction builder (`SurrealDB.Multi`) and runner (`SurrealDB.transaction/2`, `Store.transaction/1`) that assembles typed, Zoi-validated CRUD steps plus raw SurrealQL into one atomic `BEGIN … COMMIT` block.

**Architecture:** `SurrealDB.Multi` is pure data + assembly (no I/O): it validates each step client-side, namespaces per-step variables, LET-binds every step by its step name, and emits a single block ending in `RETURN { name: $name, … }` so results map back by key. `SurrealDB.transaction/2` sends the block through the existing `SurrealDB.query/3` path and hydrates the name-keyed RETURN payload. Statement fragments are extracted from `SurrealDB.Repo` into `SurrealDB.Repo.Statement` so Repo and Multi share one source of truth. Atomicity is server-side.

**Spike revision:** Task 1 is complete; see `docs/superpowers/plans/2026-07-03-transactions-multi-spike-findings.md`. SurrealDB 3.1.5 returns one result entry for `BEGIN`, each step `LET`, the terminal `RETURN`, and `COMMIT`. Therefore success mapping reads the RETURN payload at response index `length(ops) + 1` instead of `List.last(results)`, and server error attribution maps response statement index `i` to step index `i - 1` when `1 <= i <= length(ops)`. `ensure_query_success/1` must skip the observed generic rollback/cancel/COMMIT-aborted messages to surface the real failing statement when present.

**Tech Stack:** Elixir library (no Phoenix). Deps already present: `req`, `jason`, `zoi`. Tests: ExUnit with stubbed `Req` adapters (see `test/surreal_db/repo_test.exs` for the pattern).

**Spec:** `docs/superpowers/specs/2026-07-03-transactions-multi-design.md` — read it before starting any task.

## Global Constraints

- Repo: `/home/michael_intandem/src/elixir_src/prototypes/hgs_surrealdb_sdk`, branch `feat/transactions-multi`. All commands run from the repo root.
- `artifacts/todo.md` is dirty in the working tree and is NOT part of this work. Never `git add` it; never `git add -A` / `git add .` / `git commit -a`. Always add exact file paths.
- No new dependencies.
- Before every commit: `mix format` then `mix test` (full suite) must pass.
- Live SurrealDB access (Tasks 1 and 8 only): `http://localhost:8000`, user `root`, password `root`, and ONLY namespace `tx_spike` / database `tx_spike`. Never run any `mix surreal.*` task — some hit real app scopes.
- Public names are fixed by the spec — do not rename: `SurrealDB.Multi.new/0`, `create/4`, `update/5`, `delete/4`, `let/3,4`, `raw/3,4`, `to_query/1`; `SurrealDB.transaction/2`; `Store.transaction/1` (macro-generated).
- Result contract (all runner paths): `{:ok, %{step_name => result}}` or `{:error, step_name_or_:transaction, reason}`. Never a 2-tuple error from `transaction`.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

---

### Task 1: Runtime spike — verify SurrealDB transaction semantics

**Status:** Complete. Findings committed in
`docs/superpowers/plans/2026-07-03-transactions-multi-spike-findings.md`;
Tasks 5-6 below have been revised to match those findings.

The whole design leans on how the live server treats `LET`/`RETURN` inside `BEGIN/COMMIT`. Verify before building. This task produces a findings doc that gates Tasks 5–6.

**Files:**
- Create: `tmp/spike_transactions.exs` (deleted at the end — not committed)
- Create: `docs/superpowers/plans/2026-07-03-transactions-multi-spike-findings.md`

**Interfaces:**
- Produces: the findings doc with the A1–A5 assumption table filled in. Tasks 5–6 read it before implementing.

- [ ] **Step 1: Check the server is reachable**

Run: `curl -s http://localhost:8000/health && echo OK && curl -s http://localhost:8000/version`

Expected: the health request exits successfully and `/version` prints a version string (record the version). On SurrealDB 3.1.5, `/health` returned an empty successful response rather than a body containing `OK`. If the health check fails, STOP and report back — do not guess.

- [ ] **Step 2: Write the spike script**

Create `tmp/spike_transactions.exs`:

```elixir
# Spike: SurrealDB transaction semantics (see plan Task 1 / spec §5)
{:ok, client} =
  SurrealDB.connect(
    endpoint: "http://localhost:8000",
    namespace: "tx_spike",
    database: "tx_spike",
    username: "root",
    password: "root"
  )

{:ok, _} = SurrealDB.query(client, "DEFINE TABLE IF NOT EXISTS person SCHEMALESS")
{:ok, _} = SurrealDB.query(client, "DELETE person")

IO.puts("=== Q1/Q2/Q4: success — RETURN inside txn; BEGIN/COMMIT/LET entries; LET capture shape ===")

success_surql = """
BEGIN TRANSACTION;
LET $a = (CREATE person:spike_a CONTENT { name: "one" });
LET $b = (CREATE person:spike_b CONTENT { name: "two" });
RETURN { a: $a, b: $b };
COMMIT TRANSACTION;
"""

case SurrealDB.rpc(client, "query", [success_surql]) do
  {:ok, response} -> IO.inspect(response.result, label: "SUCCESS raw", limit: :infinity)
  other -> IO.inspect(other, label: "SUCCESS unexpected", limit: :infinity)
end

IO.puts("=== Q3: failure — duplicate record id forces a rollback ===")

failure_surql = """
BEGIN TRANSACTION;
LET $a = (CREATE person:spike_dup CONTENT { name: "first" });
LET $b = (CREATE person:spike_dup CONTENT { name: "second" });
RETURN { a: $a, b: $b };
COMMIT TRANSACTION;
"""

case SurrealDB.rpc(client, "query", [failure_surql]) do
  {:ok, response} -> IO.inspect(response.result, label: "FAILURE raw", limit: :infinity)
  other -> IO.inspect(other, label: "FAILURE outer error", limit: :infinity)
end

IO.puts("=== Q3b: did the rollback undo the first CREATE? (expect empty) ===")

{:ok, check} = SurrealDB.query(client, "SELECT * FROM person:spike_dup")
IO.inspect(check.results, label: "post-rollback select")

{:ok, _} = SurrealDB.query(client, "DELETE person")
IO.puts("done")
```

- [ ] **Step 3: Run it**

Run: `mix run tmp/spike_transactions.exs`

Expected: two raw response dumps and an empty post-rollback select. Capture the full output.

- [ ] **Step 4: Record findings**

Create `docs/superpowers/plans/2026-07-03-transactions-multi-spike-findings.md` with the raw output pasted in and this table filled from evidence (not from memory):

```markdown
# Spike findings — first-class transactions (2026-07-03)

SurrealDB version: <paste from /version>

## Raw output

<paste the full script output here>

## Assumption check (gates Tasks 5–6)

| # | Assumption baked into the plan | Confirmed? (yes/no + evidence line) |
|---|---|---|
| A1 | Success: the RETURN value is the sole (or last) entry in the results array | |
| A2 | BEGIN and COMMIT emit no result entries of their own | |
| A3 | Failure: one ERR entry per inner statement in statement order, so entry index i maps to step i (LETs first, RETURN last) | |
| A4 | Non-failing statements carry the generic message "The query was not executed due to a failed transaction"; the actually-failing statement carries the real error | |
| A5 | `LET $x = (CREATE …)` captures an ARRAY of created records | |

## Verdict

- [ ] All assumptions confirmed — Tasks 5–6 proceed as written.
- [ ] Some assumption failed — STOP; report to the orchestrator; Tasks 5–6 must be revised (spec §5 has the positional fallback) before execution.
```

If any assumption fails, STOP after committing the findings and report back. The recorded SurrealDB 3.1.5 spike did find failed assumptions, and this plan has since been revised so Tasks 5-6 can proceed.

- [ ] **Step 5: Clean up and commit**

```bash
rm tmp/spike_transactions.exs
git add docs/superpowers/plans/2026-07-03-transactions-multi-spike-findings.md
git commit -m "docs: spike findings — SurrealDB transaction semantics

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Extract `SurrealDB.Repo.Statement` builders

Pull the SurrealQL fragment construction out of `Repo.create/update/delete` so `Multi` (Task 4) can reuse it. Repo's public behavior must not change.

**Files:**
- Create: `lib/surreal_db/repo/statement.ex`
- Modify: `lib/surreal_db/repo.ex` (the `create/4`, `update/5`, `delete/4` bodies and the alias line)
- Test: `test/surreal_db/repo/statement_test.exs`

**Interfaces:**
- Produces (consumed by Task 4):
  - `Statement.create(schema, attrs)` → `{:ok, {surql :: String.t(), vars :: map()}} | {:error, %SurrealDB.Schema.ValidationError{}}`
  - `Statement.update(schema, id, attrs)` → `{:ok, {surql, vars}} | {:error, %SurrealDB.Error{type: :invalid_identifier}}`
  - `Statement.delete(schema, id)` → same error shape as update

- [ ] **Step 1: Write the failing tests**

Create `test/surreal_db/repo/statement_test.exs`:

```elixir
defmodule SurrealDB.Repo.StatementTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Repo.Statement
  alias SurrealDB.Schema.ValidationError

  defmodule User do
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

  test "create/2 validates attrs and builds CREATE with nil-stripped content" do
    assert {:ok, {surql, vars}} =
             Statement.create(User, %{name: "Jane", email: "jane@example.com"})

    assert surql == "CREATE type::table($__table__) CONTENT $attrs"
    assert vars[:__table__] == "user"

    assert Jason.decode!(Jason.encode!(vars[:attrs])) ==
             %{"name" => "Jane", "email" => "jane@example.com"}
  end

  test "create/2 surfaces Zoi validation errors" do
    assert {:error, %ValidationError{}} = Statement.create(User, %{name: "Jane"})
  end

  test "update/3 builds UPDATE MERGE and validates the record id" do
    assert {:ok, {"UPDATE user:abc MERGE $attrs", %{attrs: %{name: "X"}}}} =
             Statement.update(User, "user:abc", %{name: "X"})

    assert {:error, %SurrealDB.Error{type: :invalid_identifier}} =
             Statement.update(User, "user; DROP", %{name: "X"})
  end

  test "delete/2 builds DELETE RETURN BEFORE and validates the record id" do
    assert {:ok, {"DELETE user:abc RETURN BEFORE", %{}}} = Statement.delete(User, "user:abc")

    assert {:error, %SurrealDB.Error{type: :invalid_identifier}} =
             Statement.delete(User, "user; DROP")
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/surreal_db/repo/statement_test.exs`
Expected: FAIL — `SurrealDB.Repo.Statement` is not available.

- [ ] **Step 3: Implement the module**

Create `lib/surreal_db/repo/statement.ex`:

```elixir
defmodule SurrealDB.Repo.Statement do
  @moduledoc false

  # Shared SurrealQL statement builders — the single source of truth for the
  # fragments the typed CRUD helpers emit. Used by `SurrealDB.Repo` (one
  # statement per query) and `SurrealDB.Multi` (statements composed into a
  # transaction block).

  alias SurrealDB.Identifier

  @spec create(module(), map()) ::
          {:ok, {String.t(), map()}} | {:error, SurrealDB.Schema.ValidationError.t()}
  def create(schema, attrs) do
    with {:ok, validated} <- schema.validate(attrs) do
      content = validated |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()

      {:ok,
       {"CREATE type::table($__table__) CONTENT $attrs",
        %{__table__: schema.__table__(), attrs: content}}}
    end
  end

  @spec update(module(), String.t(), map()) ::
          {:ok, {String.t(), map()}} | {:error, SurrealDB.Error.t()}
  def update(_schema, id, attrs) do
    with {:ok, identifier} <- Identifier.validate(id) do
      {:ok, {"UPDATE #{identifier} MERGE $attrs", %{attrs: attrs}}}
    end
  end

  @spec delete(module(), String.t()) ::
          {:ok, {String.t(), map()}} | {:error, SurrealDB.Error.t()}
  def delete(_schema, id) do
    with {:ok, identifier} <- Identifier.validate(id) do
      {:ok, {"DELETE #{identifier} RETURN BEFORE", %{}}}
    end
  end
end
```

- [ ] **Step 4: Refactor `SurrealDB.Repo` to use it**

In `lib/surreal_db/repo.ex`:

Change the alias line

```elixir
  alias SurrealDB.Repo.FilterBuilder
```

to

```elixir
  alias SurrealDB.Repo.{FilterBuilder, Statement}
```

Replace the bodies of `create/4`, `update/5`, `delete/4` (keep specs and heads):

```elixir
  def create(%Client{} = client, schema, attrs, _opts \\ []) do
    with {:ok, {surql, vars}} <- Statement.create(schema, attrs) do
      run_one(client, schema, surql, vars)
    end
  end
```

```elixir
  def update(%Client{} = client, schema, id, attrs, _opts \\ []) do
    with {:ok, {surql, vars}} <- Statement.update(schema, id, attrs) do
      run_one(client, schema, surql, vars)
    end
  end
```

```elixir
  def delete(%Client{} = client, schema, id, _opts \\ []) do
    with {:ok, {surql, vars}} <- Statement.delete(schema, id) do
      run_one(client, schema, surql, vars)
    end
  end
```

- [ ] **Step 5: Run the new tests and the full suite**

Run: `mix test test/surreal_db/repo/statement_test.exs` — Expected: PASS
Run: `mix test` — Expected: PASS (Repo behavior unchanged; existing `repo_test.exs` asserts the exact same request bodies)

- [ ] **Step 6: Format and commit**

```bash
mix format
git add lib/surreal_db/repo/statement.ex lib/surreal_db/repo.ex test/surreal_db/repo/statement_test.exs
git commit -m "refactor: extract shared CRUD statement builders from Repo

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `SurrealDB.Multi` — struct and step builders

Pure data structure: ordered ops with build-time name checks. No SurrealQL yet.

**Files:**
- Create: `lib/surreal_db/multi.ex`
- Test: `test/surreal_db/multi_test.exs`

**Interfaces:**
- Produces (consumed by Tasks 4, 6, 7):
  - `%SurrealDB.Multi{ops: [map()]}` — each op is `%{name: atom, kind: :create | :update | :delete | :let | :raw, ...}`; op order = execution order
  - `Multi.new/0`, `Multi.create(multi, name, schema, attrs)`, `Multi.update(multi, name, schema, id, attrs)`, `Multi.delete(multi, name, schema, id)`, `Multi.let(multi, name, surql, vars \\ %{})`, `Multi.raw(multi, name, surql, vars \\ %{})`
  - Duplicate or non-identifier step names raise `ArgumentError` at build time

- [ ] **Step 1: Write the failing tests**

Create `test/surreal_db/multi_test.exs`:

```elixir
defmodule SurrealDB.MultiTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Multi

  defmodule User do
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

  defmodule Account do
    use SurrealDB.Schema

    table "account"

    schema do
      Zoi.object(%{
        id: Zoi.string() |> Zoi.optional(),
        owner: Zoi.string() |> Zoi.optional(),
        balance: Zoi.integer()
      })
    end
  end

  test "new/0 starts with no ops" do
    assert %Multi{ops: []} = Multi.new()
  end

  test "steps accumulate in pipeline order with their kinds" do
    multi =
      Multi.new()
      |> Multi.create(:user, User, %{name: "Jane", email: "jane@example.com"})
      |> Multi.update(:acct, Account, "account:abc", %{balance: 250})
      |> Multi.delete(:old, User, "user:old")
      |> Multi.let(:owner, "SELECT * FROM $user.id")
      |> Multi.raw(:rel, "RELATE $owner->owns->$acct")

    assert Enum.map(multi.ops, &{&1.name, &1.kind}) == [
             {:user, :create},
             {:acct, :update},
             {:old, :delete},
             {:owner, :let},
             {:rel, :raw}
           ]
  end

  test "duplicate step names raise ArgumentError" do
    assert_raise ArgumentError, ~r/already in this multi/, fn ->
      Multi.new()
      |> Multi.raw(:a, "RETURN 1")
      |> Multi.raw(:a, "RETURN 2")
    end
  end

  test "step names must be valid identifiers" do
    assert_raise ArgumentError, ~r/valid identifier/, fn ->
      Multi.new() |> Multi.raw(:"bad name", "RETURN 1")
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/surreal_db/multi_test.exs`
Expected: FAIL — `SurrealDB.Multi` is not available.

- [ ] **Step 3: Implement the module**

Create `lib/surreal_db/multi.ex`:

```elixir
defmodule SurrealDB.Multi do
  @moduledoc """
  An `Ecto.Multi`-style builder that composes typed, Zoi-validated operations
  and raw SurrealQL into a single atomic `BEGIN … COMMIT` transaction block.

      multi =
        SurrealDB.Multi.new()
        |> SurrealDB.Multi.create(:user, MyApp.User, %{name: "Jane", email: "jane@example.com"})
        |> SurrealDB.Multi.update(:acct, MyApp.Account, "account:abc", %{balance: 100})
        |> SurrealDB.Multi.let(:owner, "SELECT * FROM $user.id")
        |> SurrealDB.Multi.raw(:rel, "RELATE $owner->owns->$acct")

      MyApp.SurrealStore.transaction(multi)
      #=> {:ok, %{user: %MyApp.User{}, acct: %MyApp.Account{}, owner: [...], rel: [...]}}
      #=> {:error, step_name, reason}

  Every step is LET-bound by its step name, so later `let`/`raw` steps can
  reference earlier results as `$<step_name>`. Step names must be unique,
  valid identifiers; violations raise `ArgumentError` at build time.

  Atomicity is server-side: on any failing statement SurrealDB rolls back the
  whole block and the runner returns `{:error, step_name, reason}` — there are
  never partial writes. `let`/`raw` fragments are wrapped as subquery
  expressions (`LET $name = (<surql>);`), so they must be expressions —
  DDL statements such as `DEFINE` do not belong in a multi.
  """

  alias SurrealDB.Repo.Statement

  @type step_name :: atom()
  @type t :: %__MODULE__{ops: [map()]}

  defstruct ops: []

  @name_pattern ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec create(t(), step_name(), module(), map()) :: t()
  def create(%__MODULE__{} = multi, name, schema, attrs)
      when is_atom(name) and is_atom(schema) and is_map(attrs) do
    add(multi, %{name: name, kind: :create, schema: schema, attrs: attrs})
  end

  @spec update(t(), step_name(), module(), String.t(), map()) :: t()
  def update(%__MODULE__{} = multi, name, schema, id, attrs)
      when is_atom(name) and is_atom(schema) and is_map(attrs) do
    add(multi, %{name: name, kind: :update, schema: schema, id: id, attrs: attrs})
  end

  @spec delete(t(), step_name(), module(), String.t()) :: t()
  def delete(%__MODULE__{} = multi, name, schema, id)
      when is_atom(name) and is_atom(schema) do
    add(multi, %{name: name, kind: :delete, schema: schema, id: id})
  end

  @spec let(t(), step_name(), iodata(), map()) :: t()
  def let(%__MODULE__{} = multi, name, surql, vars \\ %{})
      when is_atom(name) and is_map(vars) do
    add(multi, %{name: name, kind: :let, surql: IO.iodata_to_binary(surql), vars: vars})
  end

  @spec raw(t(), step_name(), iodata(), map()) :: t()
  def raw(%__MODULE__{} = multi, name, surql, vars \\ %{})
      when is_atom(name) and is_map(vars) do
    add(multi, %{name: name, kind: :raw, surql: IO.iodata_to_binary(surql), vars: vars})
  end

  defp add(%__MODULE__{ops: ops} = multi, op) do
    validate_name!(op.name, ops)
    %{multi | ops: ops ++ [op]}
  end

  defp validate_name!(name, ops) do
    unless Regex.match?(@name_pattern, Atom.to_string(name)) do
      raise ArgumentError,
            "step name #{inspect(name)} must be a valid identifier " <>
              "(letters, digits, underscore — it becomes a $#{name} binding)"
    end

    if Enum.any?(ops, &(&1.name == name)) do
      raise ArgumentError, "step name #{inspect(name)} is already in this multi"
    end
  end
end
```

Note: `alias SurrealDB.Repo.Statement` is unused until Task 4 — the compiler
will warn. That is expected and resolved in Task 4; if the warning bothers the
suite, remove the alias here and re-add it in Task 4.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/surreal_db/multi_test.exs`
Expected: PASS

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/surreal_db/multi.ex test/surreal_db/multi_test.exs
git commit -m "feat: add SurrealDB.Multi step builders

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `Multi.to_query/1` — validation, namespacing, block assembly

**Files:**
- Modify: `lib/surreal_db/multi.ex`
- Test: `test/surreal_db/multi_test.exs` (append tests)

**Interfaces:**
- Consumes: `SurrealDB.Repo.Statement.create/2`, `update/3`, `delete/2` (Task 2)
- Produces (consumed by Task 6): `Multi.to_query(multi)` → `{:ok, surql :: String.t(), vars :: %{String.t() => term()}} | {:error, step_name :: atom(), reason :: term()}`

- [ ] **Step 1: Write the failing tests**

Append inside `test/surreal_db/multi_test.exs` (before the final `end`; add `alias SurrealDB.Schema.ValidationError` next to the existing alias):

```elixir
  test "to_query/1 assembles a BEGIN/LET/RETURN/COMMIT block with namespaced vars" do
    {:ok, surql, vars} =
      Multi.new()
      |> Multi.create(:user, User, %{name: "Jane", email: "jane@example.com"})
      |> Multi.update(:acct, Account, "account:abc", %{balance: 250})
      |> Multi.let(:owner, "SELECT * FROM $user.id")
      |> Multi.raw(:rel, "RELATE $owner->owns->$acct")
      |> Multi.to_query()

    assert String.split(surql, "\n") == [
             "BEGIN TRANSACTION;",
             "LET $user = (CREATE type::table($s0___table__) CONTENT $s0_attrs);",
             "LET $acct = (UPDATE account:abc MERGE $s1_attrs);",
             "LET $owner = (SELECT * FROM $user.id);",
             "LET $rel = (RELATE $owner->owns->$acct);",
             "RETURN { user: $user, acct: $acct, owner: $owner, rel: $rel };",
             "COMMIT TRANSACTION;"
           ]

    assert vars["s0___table__"] == "user"

    assert Jason.decode!(Jason.encode!(vars["s0_attrs"])) ==
             %{"name" => "Jane", "email" => "jane@example.com"}

    assert Jason.decode!(Jason.encode!(vars["s1_attrs"])) == %{"balance" => 250}
    assert map_size(vars) == 3
  end

  test "to_query/1 namespaces let/raw vars but leaves step references alone" do
    {:ok, surql, vars} =
      Multi.new()
      |> Multi.raw(:adults, "SELECT * FROM person WHERE age > $min", %{min: 21})
      |> Multi.to_query()

    assert surql =~ "LET $adults = (SELECT * FROM person WHERE age > $s0_min);"
    assert vars == %{"s0_min" => 21}
  end

  test "to_query/1 short-circuits on the first invalid step with its name" do
    assert {:error, :bad_user, %ValidationError{}} =
             Multi.new()
             |> Multi.create(:ok_user, User, %{name: "Jane", email: "jane@example.com"})
             |> Multi.create(:bad_user, User, %{name: "NoEmail"})
             |> Multi.to_query()
  end

  test "to_query/1 rejects an invalid update id with the step name" do
    assert {:error, :acct, %SurrealDB.Error{type: :invalid_identifier}} =
             Multi.new()
             |> Multi.update(:acct, Account, "account; DROP", %{balance: 1})
             |> Multi.to_query()
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/surreal_db/multi_test.exs`
Expected: FAIL — `Multi.to_query/1` is undefined.

- [ ] **Step 3: Implement `to_query/1`**

Append to `lib/surreal_db/multi.ex` before the private `add/2` function (keep the `alias SurrealDB.Repo.Statement` from Task 3):

```elixir
  @variable_pattern ~r/\$([A-Za-z_][A-Za-z0-9_]*)/

  @doc """
  Validates every step and assembles the transaction block.

  Returns `{:ok, surql, vars}` where `surql` is the full
  `BEGIN … RETURN … COMMIT` block and `vars` is the merged, per-step
  namespaced variable map, or `{:error, step_name, reason}` for the first
  invalid step (Zoi validation or identifier failure) — nothing is sent in
  that case.
  """
  @spec to_query(t()) :: {:ok, String.t(), map()} | {:error, step_name(), term()}
  def to_query(%__MODULE__{ops: ops}) do
    ops
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], %{}}, fn {op, index}, {:ok, lines, vars} ->
      case build_op(op, index) do
        {:ok, fragment, op_vars} ->
          line = "LET $#{op.name} = (#{fragment});"
          {:cont, {:ok, [line | lines], Map.merge(vars, op_vars)}}

        {:error, reason} ->
          {:halt, {:error, op.name, reason}}
      end
    end)
    |> case do
      {:ok, lines, vars} ->
        return_line =
          "RETURN { " <> Enum.map_join(ops, ", ", &"#{&1.name}: $#{&1.name}") <> " };"

        surql =
          Enum.join(
            ["BEGIN TRANSACTION;"] ++
              Enum.reverse(lines) ++ [return_line, "COMMIT TRANSACTION;"],
            "\n"
          )

        {:ok, surql, vars}

      {:error, name, reason} ->
        {:error, name, reason}
    end
  end

  defp build_op(%{kind: :create, schema: schema, attrs: attrs}, index) do
    namespace_statement(Statement.create(schema, attrs), index)
  end

  defp build_op(%{kind: :update, schema: schema, id: id, attrs: attrs}, index) do
    namespace_statement(Statement.update(schema, id, attrs), index)
  end

  defp build_op(%{kind: :delete, schema: schema, id: id}, index) do
    namespace_statement(Statement.delete(schema, id), index)
  end

  defp build_op(%{kind: kind, surql: surql, vars: vars}, index) when kind in [:let, :raw] do
    namespace_statement({:ok, {surql, vars}}, index)
  end

  defp namespace_statement({:ok, {surql, vars}}, index) do
    string_vars = Map.new(vars, fn {key, value} -> {to_string(key), value} end)

    fragment =
      Regex.replace(@variable_pattern, surql, fn full, name ->
        if Map.has_key?(string_vars, name), do: "$s#{index}_#{name}", else: full
      end)

    namespaced = Map.new(string_vars, fn {key, value} -> {"s#{index}_#{key}", value} end)
    {:ok, fragment, namespaced}
  end

  defp namespace_statement({:error, reason}, _index), do: {:error, reason}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/surreal_db/multi_test.exs`
Expected: PASS. Then `mix test` — Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/surreal_db/multi.ex test/surreal_db/multi_test.exs
git commit -m "feat: assemble Multi into a BEGIN/LET/RETURN/COMMIT block

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Statement-index attribution in query errors

`SurrealDB.query/3` currently reports the FIRST `status: "ERR"` statement. In a rolled-back transaction most statements carry the generic "not executed" message and the real failure can sit later — and the runner (Task 6) needs the failing statement's index to name the step.

**GATE: read `docs/superpowers/plans/2026-07-03-transactions-multi-spike-findings.md` first.** A3/A4 were only partially confirmed on SurrealDB 3.1.5, so this task is revised from the original direct mapping: preserve the raw response `statement_index`, but choose the first non-generic transaction error when one exists. The runner in Task 6 applies the transaction block offset.

**Files:**
- Modify: `lib/surreal_db.ex` (`ensure_query_success/1`)
- Modify: `lib/surreal_db/error.ex` (`surreal_error/1` → `surreal_error/2` with default)
- Test: `test/surreal_db/query_error_index_test.exs`

**Interfaces:**
- Produces (consumed by Task 6): query errors of type `:surreal_error` carry `details.statement_index` (0-based index into the response's statement array) whenever the response body is a list. `Error.surreal_error/1` still works unchanged (no index key added when nil).

- [ ] **Step 1: Write the failing tests**

Create `test/surreal_db/query_error_index_test.exs`:

```elixir
defmodule SurrealDB.QueryErrorIndexTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Client

  @failed "The query was not executed due to a failed transaction"
  @cancelled "The query was not executed due to a cancelled transaction"
  @commit_aborted "Cannot COMMIT: the transaction was aborted due to a prior error"

  defp client_with_response(statements) do
    %Client{
      endpoint: "http://localhost:8000",
      namespace: "test",
      database: "app",
      auth: {:basic, %{username: "root", password: "root"}},
      request_options: [
        adapter: fn request ->
          {request, Req.Response.new(status: 200, body: Jason.encode!(statements))}
        end
      ]
    }
  end

  test "query error carries the failing statement's index" do
    client =
      client_with_response([
        %{"status" => "OK", "result" => []},
        %{"status" => "ERR", "result" => "boom"}
      ])

    assert {:error, %SurrealDB.Error{type: :surreal_error, details: %{statement_index: 1}}} =
             SurrealDB.query(client, "RETURN 1; RETURN 2;")
  end

  test "generic rollback entries lose to the statement that actually failed" do
    client =
      client_with_response([
        %{"status" => "OK", "result" => nil},
        %{"status" => "ERR", "result" => @failed},
        %{"status" => "ERR", "result" => "Database record `person:dup` already exists"},
        %{"status" => "ERR", "result" => @cancelled},
        %{"status" => "ERR", "result" => @commit_aborted}
      ])

    assert {:error, %SurrealDB.Error{message: message, details: %{statement_index: 2}}} =
             SurrealDB.query(client, "BEGIN TRANSACTION; RETURN 1; COMMIT TRANSACTION;")

    assert message =~ "already exists"
  end

  test "all-generic entries fall back to the first ERR entry" do
    client =
      client_with_response([
        %{"status" => "ERR", "result" => @failed},
        %{"status" => "ERR", "result" => @cancelled},
        %{"status" => "ERR", "result" => @commit_aborted}
      ])

    assert {:error, %SurrealDB.Error{details: %{statement_index: 0}}} =
             SurrealDB.query(client, "BEGIN TRANSACTION; RETURN 1; COMMIT TRANSACTION;")
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/surreal_db/query_error_index_test.exs`
Expected: FAIL — `details` has no `statement_index` key.

- [ ] **Step 3: Implement**

In `lib/surreal_db.ex`, replace the existing `ensure_query_success/1` clauses (currently near the bottom, using `Enum.find`) with:

```elixir
  @generic_transaction_errors MapSet.new([
                                "The query was not executed due to a failed transaction",
                                "The query was not executed due to a cancelled transaction",
                                "Cannot COMMIT: the transaction was aborted due to a prior error"
                              ])

  defp ensure_query_success(body) when is_list(body) do
    body
    |> Enum.with_index()
    |> Enum.filter(fn {statement, _index} -> Map.get(statement, "status") == "ERR" end)
    |> case do
      [] ->
        :ok

      errors ->
        {statement, index} =
          Enum.find(errors, hd(errors), fn {statement, _index} ->
            not MapSet.member?(@generic_transaction_errors, Map.get(statement, "result"))
          end)

        {:error, Error.surreal_error(statement, index)}
    end
  end

  defp ensure_query_success(_body), do: :ok
```

In `lib/surreal_db/error.ex`, replace `surreal_error/1` with:

```elixir
  @spec surreal_error(map(), non_neg_integer() | nil) :: t()
  def surreal_error(statement, statement_index \\ nil) do
    details = Map.take(statement, ["detail", "status", "time"])

    details =
      if is_integer(statement_index),
        do: Map.put(details, :statement_index, statement_index),
        else: details

    %__MODULE__{
      type: :surreal_error,
      code: statement["code"],
      message: statement["detail"] || statement["result"] || "SurrealDB query failed",
      details: details,
      raw: statement
    }
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/surreal_db/query_error_index_test.exs` — Expected: PASS
Run: `mix test` — Expected: PASS (the behavior change for pre-existing callers is only the added details key and better error selection inside failed transactions)

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/surreal_db.ex lib/surreal_db/error.ex test/surreal_db/query_error_index_test.exs
git commit -m "feat: attribute query errors to their statement index

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: `SurrealDB.transaction/2` runner

**GATE: read `docs/superpowers/plans/2026-07-03-transactions-multi-spike-findings.md` first.** The success-mapping and attribution below are already revised for the SurrealDB 3.1.5 findings: BEGIN and COMMIT emit response entries; the RETURN payload is at response index `length(ops) + 1`; response statement index `i` maps to step index `i - 1` for `1 <= i <= length(ops)`.

**Files:**
- Modify: `lib/surreal_db.ex`
- Test: `test/surreal_db/transaction_test.exs`

**Interfaces:**
- Consumes: `Multi.to_query/1` (Task 4), `details.statement_index` on `:surreal_error` (Task 5), `schema.hydrate/1` (existing)
- Produces (consumed by Task 7): `SurrealDB.transaction(client, multi)` → `{:ok, %{atom() => term()}} | {:error, atom(), term()}` (the error step slot is a step name or `:transaction`)

- [ ] **Step 1: Write the failing tests**

Create `test/surreal_db/transaction_test.exs`:

```elixir
defmodule SurrealDB.TransactionTest do
  use ExUnit.Case, async: true

  alias SurrealDB.{Client, Multi}
  alias SurrealDB.Schema.ValidationError

  defmodule User do
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

  defp client_with_adapter(adapter) do
    %Client{
      endpoint: "http://localhost:8000",
      namespace: "test",
      database: "app",
      auth: {:basic, %{username: "root", password: "root"}},
      request_options: [adapter: adapter]
    }
  end

  defp response(statements) do
    fn request ->
      {request, Req.Response.new(status: 200, body: Jason.encode!(statements))}
    end
  end

  @jane %{"id" => "user:1", "name" => "Jane", "email" => "jane@example.com"}
  @failed "The query was not executed due to a failed transaction"
  @cancelled "The query was not executed due to a cancelled transaction"
  @commit_aborted "Cannot COMMIT: the transaction was aborted due to a prior error"

  test "empty multi returns {:ok, %{}} without touching the network" do
    client = client_with_adapter(fn _request -> raise "network must not be called" end)

    assert {:ok, %{}} = SurrealDB.transaction(client, Multi.new())
  end

  test "success maps the RETURN payload to step names and hydrates schema steps" do
    returned = %{"user" => [@jane], "count" => 1}

    client =
      client_with_adapter(
        response([
          %{"status" => "OK", "result" => nil},
          %{"status" => "OK", "result" => nil},
          %{"status" => "OK", "result" => nil},
          %{"status" => "OK", "result" => returned},
          %{"status" => "OK", "result" => nil}
        ])
      )

    multi =
      Multi.new()
      |> Multi.create(:user, User, %{name: "Jane", email: "jane@example.com"})
      |> Multi.raw(:count, "SELECT count() FROM user GROUP ALL")

    assert {:ok, %{user: %User{id: "user:1", name: "Jane"}, count: 1}} =
             SurrealDB.transaction(client, multi)
  end

  test "validation failure aborts before any network call" do
    client = client_with_adapter(fn _request -> raise "network must not be called" end)

    multi = Multi.new() |> Multi.create(:user, User, %{name: "Jane"})

    assert {:error, :user, %ValidationError{}} = SurrealDB.transaction(client, multi)
  end

  test "server rollback attributes the error to the failing step" do
    client =
      client_with_adapter(
        response([
          %{"status" => "OK", "result" => nil},
          %{"status" => "ERR", "result" => @failed},
          %{"status" => "ERR", "result" => "Database record `user:dup` already exists"},
          %{"status" => "ERR", "result" => @cancelled},
          %{"status" => "ERR", "result" => @commit_aborted}
        ])
      )

    multi =
      Multi.new()
      |> Multi.create(:a, User, %{name: "A", email: "a@example.com"})
      |> Multi.raw(:b, "CREATE user:dup")

    assert {:error, :b, %SurrealDB.Error{type: :surreal_error}} =
             SurrealDB.transaction(client, multi)
  end

  test "transport failure attributes to :transaction" do
    client =
      client_with_adapter(fn request ->
        {request, Req.Response.new(status: 500, body: "boom")}
      end)

    multi = Multi.new() |> Multi.create(:user, User, %{name: "J", email: "j@example.com"})

    assert {:error, :transaction, %SurrealDB.Error{}} = SurrealDB.transaction(client, multi)
  end

  test "hydration failure after commit surfaces the step and a ValidationError" do
    returned = %{"user" => [%{"id" => "user:1"}]}

    client =
      client_with_adapter(
        response([
          %{"status" => "OK", "result" => nil},
          %{"status" => "OK", "result" => nil},
          %{"status" => "OK", "result" => returned},
          %{"status" => "OK", "result" => nil}
        ])
      )

    multi =
      Multi.new() |> Multi.create(:user, User, %{name: "Jane", email: "jane@example.com"})

    assert {:error, :user, %ValidationError{}} = SurrealDB.transaction(client, multi)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/surreal_db/transaction_test.exs`
Expected: FAIL — `SurrealDB.transaction/2` is undefined.

- [ ] **Step 3: Implement the runner**

In `lib/surreal_db.ex`:

Add to the alias block at the top:

```elixir
  alias SurrealDB.Multi
```

Add after `query/3` (keep `query/3` unchanged):

```elixir
  @doc """
  Runs a `SurrealDB.Multi` as one atomic transaction.

  Assembles the multi into a `BEGIN … RETURN … COMMIT` block, validates every
  step client-side first (Zoi + identifier checks; an invalid step aborts
  before anything is sent), and maps the transaction's RETURN payload back to
  step names, hydrating schema-backed steps.

  Returns `{:ok, %{step_name => result}}` or `{:error, step_name, reason}` —
  the step slot is `:transaction` when the failure cannot be attributed to a
  single step (e.g. transport errors). On any server-side failure SurrealDB
  rolls back the whole block; there are never partial writes.

  Note: a hydration failure on the response means the transaction **has
  committed** but the returned record did not match the schema.
  """
  @spec transaction(Client.t(), Multi.t()) ::
          {:ok, %{atom() => term()}} | {:error, atom(), term()}
  def transaction(%Client{}, %Multi{ops: []}), do: {:ok, %{}}

  def transaction(%Client{} = client, %Multi{} = multi) do
    with {:ok, surql, vars} <- Multi.to_query(multi),
         {:ok, %QueryResult{} = result} <- query(client, surql, vars) do
      map_transaction_success(multi, result)
    else
      {:error, name, reason} -> {:error, name, reason}
      {:error, %Error{} = error} -> {:error, attribute_step(multi, error), error}
    end
  end

  defp map_transaction_success(%Multi{ops: ops}, %QueryResult{results: results, raw: raw}) do
    return_index = length(ops) + 1

    case Enum.at(results, return_index) do
      %{} = returned -> hydrate_steps(ops, returned)
      _other -> {:error, :transaction, Error.unexpected_response(raw)}
    end
  end

  defp hydrate_steps(ops, returned) do
    Enum.reduce_while(ops, {:ok, %{}}, fn op, {:ok, acc} ->
      value = Map.get(returned, Atom.to_string(op.name))

      case hydrate_step(op, value) do
        {:ok, hydrated} -> {:cont, {:ok, Map.put(acc, op.name, hydrated)}}
        {:error, reason} -> {:halt, {:error, op.name, reason}}
      end
    end)
  end

  defp hydrate_step(%{kind: kind, schema: schema}, value)
       when kind in [:create, :update, :delete] do
    case normalize_record(value) do
      nil -> {:ok, nil}
      record -> schema.hydrate(record)
    end
  end

  defp hydrate_step(_op, value), do: {:ok, value}

  defp normalize_record([record | _rest]), do: record
  defp normalize_record([]), do: nil
  defp normalize_record(%{} = record), do: record
  defp normalize_record(_other), do: nil

  # SurrealDB 3.1.5 emits entries for BEGIN, each step LET, RETURN, and
  # COMMIT. Therefore response index 0 is BEGIN and response index i maps to
  # step index i - 1 only when i is within the step range.
  defp attribute_step(%Multi{ops: ops}, %Error{
         type: :surreal_error,
         details: %{statement_index: index}
       })
       when is_integer(index) do
    step_index = index - 1

    if step_index >= 0 do
      case Enum.at(ops, step_index) do
        %{name: name} -> name
        nil -> :transaction
      end
    else
      :transaction
    end
  end

  defp attribute_step(_multi, _error), do: :transaction
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/surreal_db/transaction_test.exs` — Expected: PASS
Run: `mix test` — Expected: PASS

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/surreal_db.ex test/surreal_db/transaction_test.exs
git commit -m "feat: add SurrealDB.transaction/2 multi runner

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: `Store.transaction/1` delegate

**Files:**
- Modify: `lib/surreal_db/store.ex`
- Test: `test/surreal_db/store/transaction_test.exs`

**Interfaces:**
- Consumes: `SurrealDB.transaction/2` (Task 6)
- Produces: macro-generated `MyStore.transaction(multi)` with the same 3-tuple contract; a client/config failure is reported as `{:error, :transaction, %SurrealDB.Error{}}`

- [ ] **Step 1: Write the failing test**

Create `test/surreal_db/store/transaction_test.exs`:

```elixir
defmodule SurrealDB.Store.TransactionTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Multi

  defmodule UnstartedStore do
    use SurrealDB.Store, otp_app: :hgs_surrealdb_sdk
  end

  test "transaction/1 on a store that is not started returns a :transaction error" do
    assert {:error, :transaction, %SurrealDB.Error{type: :not_started}} =
             UnstartedStore.transaction(Multi.new())
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/surreal_db/store/transaction_test.exs`
Expected: FAIL — `transaction/1` is undefined (UndefinedFunctionError).

- [ ] **Step 3: Implement the delegate**

In `lib/surreal_db/store.ex`, inside the `quote` block, after the `delete/3` definition and before the `# Schema query` comment, add:

```elixir
      # Transactions (delegates to SurrealDB.transaction/2)
      def transaction(%SurrealDB.Multi{} = multi) do
        case client() do
          {:ok, c} -> SurrealDB.transaction(c, multi)
          {:error, error} -> {:error, :transaction, error}
        end
      end
```

Also add one line to the `Store` moduledoc's usage example (after the `MyApp.SurrealStore.create(...)` line):

```elixir
      MyApp.SurrealStore.transaction(multi)   # see SurrealDB.Multi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/surreal_db/store/transaction_test.exs` — Expected: PASS
Run: `mix test` — Expected: PASS

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/surreal_db/store.ex test/surreal_db/store/transaction_test.exs
git commit -m "feat: add Store.transaction/1 delegate

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Docs, roadmap, full verification, live end-to-end run

**Files:**
- Modify: `README.md` (add a Transactions section)
- Modify: `ROADMAP.md` (move the first-class-transactions item to done, matching how gen.context was recorded — read the file to see the pattern)
- Create: `tmp/verify_transactions.exs` (deleted at the end — not committed)

**Interfaces:**
- Consumes: everything from Tasks 2–7 against the live server.

- [ ] **Step 1: Add the README section**

Read `README.md`, find where Store/Repo usage is documented, and add a sibling section with this content (match the heading level used by its neighbors):

````markdown
## Transactions

Compose typed, Zoi-validated operations — plus raw SurrealQL — into one
atomic `BEGIN … COMMIT` block with `SurrealDB.Multi`:

```elixir
multi =
  SurrealDB.Multi.new()
  |> SurrealDB.Multi.create(:user, MyApp.User, %{name: "Jane", email: "jane@example.com"})
  |> SurrealDB.Multi.update(:acct, MyApp.Account, "account:abc", %{balance: 100})
  |> SurrealDB.Multi.let(:owner, "SELECT * FROM $user.id")
  |> SurrealDB.Multi.raw(:rel, "RELATE $owner->owns->$acct")

case MyApp.SurrealStore.transaction(multi) do
  {:ok, %{user: user, acct: acct}} -> ...
  {:error, step, reason} -> ...
end
```

Every step is `LET`-bound by its step name, so later `let`/`raw` steps can
reference earlier results as `$<step_name>`. Validation runs client-side
before anything is sent; on any server-side failure SurrealDB rolls back the
whole block — there are never partial writes.
````

- [ ] **Step 2: Update ROADMAP.md**

Read `ROADMAP.md`. Move the "First-class transactions (`Store.transaction/1` + a `Multi`-style builder)" bullet out of the backlog and record it as done the same way earlier completed items (e.g. gen.context) are recorded, with a pointer to the spec `docs/superpowers/specs/2026-07-03-transactions-multi-design.md`.

- [ ] **Step 3: Full-suite verification**

Run: `mix format` then `mix test`
Expected: everything passes, no formatting diffs. Paste the summary line of the test run into your report.

- [ ] **Step 4: Live end-to-end verification**

Confirm the server: `curl -s http://localhost:8000/health` (STOP and report if down).

Create `tmp/verify_transactions.exs`:

```elixir
alias SurrealDB.Multi

defmodule TxVerify.User do
  use SurrealDB.Schema

  table "spike_user"

  schema do
    Zoi.object(%{
      id: Zoi.string() |> Zoi.optional(),
      name: Zoi.string(),
      email: Zoi.string()
    })
  end
end

{:ok, client} =
  SurrealDB.connect(
    endpoint: "http://localhost:8000",
    namespace: "tx_spike",
    database: "tx_spike",
    username: "root",
    password: "root"
  )

{:ok, _} = SurrealDB.query(client, "DEFINE TABLE IF NOT EXISTS spike_user SCHEMALESS")
{:ok, _} = SurrealDB.query(client, "DELETE spike_user")

IO.puts("=== 1. commit path ===")

commit_multi =
  Multi.new()
  |> Multi.create(:jane, TxVerify.User, %{name: "Jane", email: "jane@example.com"})
  |> Multi.create(:bob, TxVerify.User, %{name: "Bob", email: "bob@example.com"})

IO.inspect(SurrealDB.transaction(client, commit_multi), label: "commit result")

{:ok, after_commit} = SurrealDB.query(client, "SELECT * FROM spike_user")
IO.inspect(after_commit.results, label: "records after commit (expect 2)")

IO.puts("=== 2. rollback path ===")

rollback_multi =
  Multi.new()
  |> Multi.create(:carol, TxVerify.User, %{name: "Carol", email: "carol@example.com"})
  |> Multi.raw(:dup1, "CREATE spike_user:dup")
  |> Multi.raw(:dup2, "CREATE spike_user:dup")

IO.inspect(SurrealDB.transaction(client, rollback_multi),
  label: "rollback result (expect {:error, :dup2, _})"
)

{:ok, after_rollback} = SurrealDB.query(client, "SELECT * FROM spike_user")
IO.inspect(after_rollback.results, label: "records after rollback (expect still 2 — no Carol, no dup)")

IO.puts("=== 3. let binding consumed by a later raw step ===")

let_multi =
  Multi.new()
  |> Multi.create(:dave, TxVerify.User, %{name: "Dave", email: "dave@example.com"})
  |> Multi.let(:dave_id, "$dave[0].id")
  |> Multi.raw(:renamed, "UPDATE $dave_id SET name = \"David\"")

IO.inspect(SurrealDB.transaction(client, let_multi), label: "let-binding result")

{:ok, dave} = SurrealDB.query(client, "SELECT name FROM spike_user WHERE email = \"dave@example.com\"")
IO.inspect(dave.results, label: "dave after rename (expect name David)")

{:ok, _} = SurrealDB.query(client, "DELETE spike_user")
IO.puts("done")
```

Run: `mix run tmp/verify_transactions.exs`

Expected: commit shows 2 hydrated structs and 2 records; rollback returns `{:error, :dup2, _}` with the record count unchanged; the let-binding flow renames Dave to David. If the `LET $dave_id = ($dave[0].id)` expression form fails, consult the spike findings for the working accessor syntax, adapt, and note the change in your report. Paste the full output into your report.

- [ ] **Step 5: Clean up, commit, report**

```bash
rm tmp/verify_transactions.exs
git add README.md ROADMAP.md
git commit -m "docs: document first-class transactions; mark roadmap item done

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

Report the full `mix test` summary and the live-verification output.
