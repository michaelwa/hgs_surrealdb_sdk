# Consistent Repo Update Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make typed partial updates validate supplied Zoi fields, reject unknown fields before dispatch, and apply the same contract to `Repo.update/5` and `Multi.update/5`.

**Architecture:** Add a generated `schema.validate_partial/1` function backed by a shared `SurrealDB.Schema.__validate_partial__/2` helper. Derive an all-optional, unknown-key-rejecting Zoi object from the schema's declared fields. Route `Repo.Statement.update/3` through that helper; `Repo` and `Multi` already share this statement builder, so they inherit one validation path. Update unit, integration, and documentation coverage without adding database schema introspection or a new raw-update API.

**Tech Stack:** Elixir, ExUnit, Zoi, SurrealDB Repo/Multi, pinned SurrealDB integration harness, Markdown documentation.

## Global Constraints

- Preserve `Repo.update`'s existing `UPDATE <id> MERGE $attrs` partial-update semantics.
- Validate only supplied fields; omitted required fields must remain valid for partial updates.
- Reject unknown top-level fields as `SurrealDB.Schema.ValidationError` before network dispatch.
- Return the validated/coerced attribute map as `$attrs`.
- Keep `Multi.update` delegated through `SurrealDB.Repo.Statement.update/3`; do not duplicate validation.
- Keep raw `SurrealDB.Repo.query/5` and `SurrealDB.Multi.raw/4` as explicit escape hatches.
- Do not introspect SurrealDB table definitions or add field-level immutability rules.
- Preserve the existing distinction between `ValidationError` for local schema failures and `SurrealDB.Error` for identifier, transport, authentication, query, and server failures.

---

## File Map

- Modify `lib/surreal_db/schema.ex`: expose `validate_partial/1` on generated schema modules and implement the shared partial-validation helper.
- Modify `lib/surreal_db/repo/statement.ex`: validate update attributes before building the existing MERGE statement.
- Modify `test/surreal_db/schema_test.exs`: cover partial validation, coercion, omitted required fields, unknown fields, and nested values.
- Modify `test/surreal_db/repo/statement_test.exs`: cover validated update variables and local failures.
- Modify `test/surreal_db/repo_test.exs`: prove invalid updates do not invoke the adapter.
- Modify `test/surreal_db/multi_test.exs`: prove direct parity and step-scoped validation errors.
- Modify `test/integration/repo_integration_test.exs`: prove omitted fields survive a valid partial update against schemafull data.
- Modify `README.md` and `docs/schema-and-repo.md`: document validation, merge semantics, unknown-field errors, and raw escape hatches.
- Create `docs/superpowers/specs/2026-07-30-consistent-repo-update-validation-design.md`: approved design already written in this workspace.
- Create `docs/superpowers/plans/2026-07-30-consistent-repo-update-validation.md`: this implementation plan.

## Task 1: Add the shared partial-schema validation API

**Files:**
- Modify: `lib/surreal_db/schema.ex`
- Test: `test/surreal_db/schema_test.exs`

**Interfaces:**
- Consumes: each schema module's existing `__schema__/0` result, a map of update attributes.
- Produces: `schema.validate_partial(attrs)` returning `{:ok, validated_map}` or `{:error, %SurrealDB.Schema.ValidationError{}}`.

- [ ] **Step 1: Write failing schema tests for partial validation**

Add tests next to the existing `validate/1` tests using the current `User` schema:

```elixir
test "validate_partial/1 accepts a subset of declared fields" do
  assert {:ok, %{age: 37}} = User.validate_partial(%{age: 37})
end

test "validate_partial/1 coerces supplied values with the field schema" do
  assert {:ok, %{age: 37}} = User.validate_partial(%{age: "37"})
end

test "validate_partial/1 rejects an invalid supplied value" do
  assert {:error, %ValidationError{}} = User.validate_partial(%{age: "not an integer"})
end

test "validate_partial/1 rejects unknown fields" do
  assert {:error, %ValidationError{errors: errors}} =
           User.validate_partial(%{nickname: "J"})

  assert Enum.any?(errors, fn %{path: path} -> path == [] or path == [:nickname] end)
end

test "validate_partial/1 validates supplied nested values" do
  assert {:error, %ValidationError{}} = UserWithProfile.validate_partial(%{profile: %{name: 12}})
end
```

Define a small `UserWithProfile` schema in the test module with a required
`profile: Zoi.object(%{name: Zoi.string()})` field. The test proves that making
top-level fields optional does not disable nested validation.

- [ ] **Step 2: Run the focused schema tests and verify failure**

Run:

```bash
mix test test/surreal_db/schema_test.exs
```

Expected: FAIL because generated schema modules do not yet define
`validate_partial/1`.

- [ ] **Step 3: Generate `validate_partial/1` from `SurrealDB.Schema`**

In the `__before_compile__/1` quoted block, add:

```elixir
@doc false
def validate_partial(params),
  do: SurrealDB.Schema.__validate_partial__(__schema__(), params)
```

Keep the existing `validate/1` implementation unchanged.

- [ ] **Step 4: Implement `__validate_partial__/2`**

Build an all-optional field object from the existing Zoi map and force
unrecognized keys to error. The implementation should follow this shape:

```elixir
@doc false
def __validate_partial__(%Zoi.Types.Map{fields: fields}, params) when is_map(params) do
  partial_schema =
    fields
    |> Map.new(fn {key, field_schema} -> {key, Zoi.optional(field_schema)} end)
    |> Zoi.object(unrecognized_keys: :error)

  case Zoi.parse(partial_schema, params, coerce: true) do
    {:ok, value} -> {:ok, value}
    {:error, errors} -> {:error, ValidationError.from_zoi(errors)}
  end
end

def __validate_partial__(_schema, params) do
  {:error,
   ValidationError.from_zoi([
     %{path: [], message: "expected a map, got: #{inspect(params)}"}
   ])}
end
```

Use the repository's installed Zoi version and verify the exact error shape
through tests rather than matching an implementation-specific Zoi error code.
Do not mutate `__schema__/0`; wrapping each field with `Zoi.optional/1` must
only affect the derived operation schema.

- [ ] **Step 5: Run the focused schema tests and verify success**

Run:

```bash
mix test test/surreal_db/schema_test.exs
```

Expected: PASS, including the pre-existing full-validation tests.

- [ ] **Step 6: Commit the shared validation boundary**

```bash
git add lib/surreal_db/schema.ex test/surreal_db/schema_test.exs
git commit -m "feat: add partial schema validation"
```

## Task 2: Route statement updates through partial validation

**Files:**
- Modify: `lib/surreal_db/repo/statement.ex`
- Test: `test/surreal_db/repo/statement_test.exs`

**Interfaces:**
- Consumes: `schema.validate_partial/1` from Task 1 and `SurrealDB.Identifier.validate/1`.
- Produces: `Statement.update/3` returning `{:ok, {surql, %{attrs: validated_attrs}}}` or the existing identifier/validation error.

- [ ] **Step 1: Add failing statement tests**

Extend the existing update tests:

```elixir
test "update/3 validates and returns coerced attributes" do
  assert {:ok, {"UPDATE user:abc MERGE $attrs", %{attrs: %{email: "jane@example.com"}}}} =
           Statement.update(User, "user:abc", %{email: "jane@example.com"})
end

test "update/3 rejects invalid values before building a statement" do
  assert {:error, %ValidationError{}} =
           Statement.update(User, "user:abc", %{email: 123})
end

test "update/3 rejects unknown fields before building a statement" do
  assert {:error, %ValidationError{}} =
           Statement.update(User, "user:abc", %{nickname: "J"})
end
```

- [ ] **Step 2: Run statement tests and verify the new tests fail**

Run:

```bash
mix test test/surreal_db/repo/statement_test.exs
```

Expected: the invalid-value and unknown-field tests fail because the current
implementation passes `attrs` directly through.

- [ ] **Step 3: Add partial validation to `Statement.update/3`**

Change the function to validate both the identifier and attributes:

```elixir
def update(schema, id, attrs) do
  with {:ok, identifier} <- Identifier.validate(id),
       {:ok, validated} <- schema.validate_partial(attrs) do
    {:ok, {"UPDATE #{identifier} MERGE $attrs", %{attrs: validated}}}
  end
end
```

Update the typespec to include `SurrealDB.Schema.ValidationError.t()` in the
error union. Keep `schema` as an argument even though it is now used for
validation; do not change the generated SurrealQL.

- [ ] **Step 4: Run statement tests and verify success**

Run:

```bash
mix test test/surreal_db/repo/statement_test.exs
```

Expected: PASS.

- [ ] **Step 5: Commit the statement boundary**

```bash
git add lib/surreal_db/repo/statement.ex test/surreal_db/repo/statement_test.exs
git commit -m "feat: validate repo update attributes"
```

## Task 3: Prove Repo and Multi behavior without duplicate validation

**Files:**
- Modify: `test/surreal_db/repo_test.exs`
- Modify: `test/surreal_db/multi_test.exs`
- Inspect only: `lib/surreal_db/repo.ex`, `lib/surreal_db/multi.ex`

**Interfaces:**
- Consumes: the validated `Statement.update/3` behavior from Task 2.
- Produces: regression coverage proving `Repo.update/5` and `Multi.update/5` share the same policy and do not dispatch invalid data.

- [ ] **Step 1: Add Repo no-dispatch tests**

Add tests using the existing `client_with_adapter/1` helper:

```elixir
test "update/4 returns a ValidationError without touching the network for invalid values" do
  client = client_with_adapter(fn _request -> raise "network must not be called" end)

  assert {:error, %ValidationError{}} =
           Repo.update(client, User, "user:abc", %{age: "not an integer"})
end

test "update/4 returns a ValidationError without touching the network for unknown fields" do
  client = client_with_adapter(fn _request -> raise "network must not be called" end)

  assert {:error, %ValidationError{}} =
           Repo.update(client, User, "user:abc", %{nickname: "J"})
end
```

- [ ] **Step 2: Add Multi parity tests**

Extend `test/surreal_db/multi_test.exs`:

```elixir
test "to_query/1 rejects invalid update values with the update step name" do
  assert {:error, :acct, %ValidationError{}} =
           Multi.new()
           |> Multi.update(:acct, Account, "account:abc", %{balance: "not an integer"})
           |> Multi.to_query()
end

test "to_query/1 rejects unknown update fields with the update step name" do
  assert {:error, :acct, %ValidationError{}} =
           Multi.new()
           |> Multi.update(:acct, Account, "account:abc", %{currency: "USD"})
           |> Multi.to_query()
end
```

Keep the existing valid transaction assembly test; its expected MERGE query
must remain unchanged.

- [ ] **Step 3: Run Repo and Multi tests**

Run:

```bash
mix test test/surreal_db/repo_test.exs test/surreal_db/multi_test.exs
```

Expected: PASS. No implementation changes should be required in `Repo` or
`Multi`, because both already route through `Statement.update/3`. If compiler
or typespec feedback requires a change, keep it limited to error typespecs and
do not add a second validation path.

- [ ] **Step 4: Commit the parity coverage**

```bash
git add test/surreal_db/repo_test.exs test/surreal_db/multi_test.exs
git commit -m "test: enforce update validation across repo and multi"
```

## Task 4: Add integration coverage for partial merge behavior

**Files:**
- Modify: `test/integration/repo_integration_test.exs`
- Inspect: `test/support/integration_case.ex`, `docker-compose.integration.yml`, `scripts/test-integration`

**Interfaces:**
- Consumes: validated `Repo.update/5` behavior from Tasks 1–3 and the existing pinned integration harness.
- Produces: an opt-in live test proving a valid partial merge preserves omitted fields against a schemafull table.

- [ ] **Step 1: Change the Repo integration table to schemafull**

In `test/integration/repo_integration_test.exs`, keep the existing `Person`
schema and table name, but change the setup query from:

```elixir
DEFINE TABLE #{@table} SCHEMALESS;
```

to:

```elixir
DEFINE TABLE #{@table} SCHEMAFULL;
DEFINE FIELD name ON TABLE #{@table} TYPE string;
DEFINE FIELD age ON TABLE #{@table} TYPE int;
```

Reuse the existing client, cleanup, and pinned Docker lifecycle. Do not modify
`IntegrationCase` or create a second integration harness.

- [ ] **Step 2: Make the existing integration update assert partial preservation**

Keep the existing create and update flow, which already updates only `age` and
asserts that `name` remains `"Jane"`. Make the assertion explicit that this is
the partial-merge contract:

```elixir
test "update validates partial fields and preserves omitted fields", %{client: client} do
  {:ok, created} = Repo.create(client, Person, %{name: "Jane", age: 36})

  assert {:ok, %Person{name: "Jane", age: 37}} =
           Repo.update(client, Person, created.id, %{age: 37})
end
```

Add a separate assertion that an unknown field returns
`{:error, %SurrealDB.Schema.ValidationError{}}`; the existing unit tests remain
the authoritative no-dispatch coverage.

- [ ] **Step 3: Run the opt-in integration test**

```bash
./scripts/test-integration
```

Expected: the integration suite passes, including the new partial-update test.

- [ ] **Step 4: Commit integration coverage**

```bash
git add test/integration/repo_integration_test.exs
git commit -m "test: cover schemafull partial repo updates"
```

## Task 5: Update public documentation and verify the full suite

**Files:**
- Modify: `README.md`
- Modify: `docs/schema-and-repo.md`

**Interfaces:**
- Consumes: the final behavior from Tasks 1–4.
- Produces: public documentation that distinguishes typed update validation from raw SurrealQL and database-side schema enforcement.

- [ ] **Step 1: Update the README contract**

In the CRUD/error guidance, state that typed `Repo` and Store updates validate
supplied attributes before dispatch, preserve omitted fields via MERGE, and
return `SurrealDB.Schema.ValidationError` for invalid or unknown fields. Add a
short raw-query note pointing readers to `Repo.query/5` and `Multi.raw/4` when
they need database-side expressions or fields outside the Zoi schema.

- [ ] **Step 2: Update `docs/schema-and-repo.md`**

Add a partial-update example and explicitly document:

```elixir
{:ok, %MyApp.User{age: 37}} =
  SurrealDB.Repo.update(client, MyApp.User, user.id, %{age: 37})

{:error, %SurrealDB.Schema.ValidationError{}} =
  SurrealDB.Repo.update(client, MyApp.User, user.id, %{unknown_field: "x"})
```

Explain that omitted required fields are allowed in updates, supplied values
are validated/coerced, unknown top-level fields are rejected, and raw queries
are the explicit escape hatch. Clarify that Zoi validation and SurrealDB's
`SCHEMAFULL` rules are independent layers; the Zoi schema is not automatically
derived from the database.

- [ ] **Step 3: Run formatting and focused tests**

Run:

```bash
mix format --check-formatted
mix test test/surreal_db/schema_test.exs test/surreal_db/repo/statement_test.exs test/surreal_db/repo_test.exs test/surreal_db/multi_test.exs
```

Expected: formatting passes and all focused tests pass.

- [ ] **Step 4: Run the complete ordinary test suite**

Run:

```bash
mix test
```

Expected: PASS; the ordinary suite remains Docker-free and continues excluding
opt-in integration tests.

- [ ] **Step 5: Review the final diff and commit documentation**

Run:

```bash
git diff --check
git status --short
git diff -- README.md docs/schema-and-repo.md
```

Confirm the only remaining unrelated change is the user's already-committed
roadmap history, then commit the documentation:

```bash
git add README.md docs/schema-and-repo.md
git commit -m "docs: document repo update validation"
```

## Final verification checklist

- [ ] `schema.validate_partial/1` accepts valid subsets and rejects unknown keys.
- [ ] Supplied values are coerced/validated through their declared Zoi field schemas.
- [ ] `Statement.update/3` returns validated `$attrs` and preserves MERGE SQL.
- [ ] Invalid values and unknown fields do not reach the network through `Repo.update/5`.
- [ ] `Multi.update/5` returns the same validation error under its step name.
- [ ] Omitted fields survive a valid partial update in the live integration suite.
- [ ] Raw `Repo.query/5` and `Multi.raw/4` are documented as explicit escape hatches.
- [ ] `README.md` and `docs/schema-and-repo.md` match the implementation.
- [ ] `mix format --check-formatted`, focused tests, `mix test`, and integration tests pass.
