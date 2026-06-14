# Feature: `HgsSurrealdbSdk.Schema` + `HgsSurrealdbSdk.Repo` facade using Zoi

## Context

Zoi is a runtime schema validation library for Elixir, inspired by Zod, focused on defining, validating, coercing, and transforming data. ([Elixir Programming Language Forum][1])

EctoShorts provides a useful pattern: a friendlier action layer over common persistence operations such as find, create, update, delete, find-or-create, and find-and-update. ([GitHub][2])

This feature should add an Ecto-inspired but HgsSurrealdbSdk-native layer to the SDK.

---

## Goal

Add two new abstractions:

```elixir
HgsSurrealdbSdk.Schema
HgsSurrealdbSdk.Repo
```

`HgsSurrealdbSdk.Schema` defines table-backed schemas using Zoi.

`HgsSurrealdbSdk.Repo` provides friendly persistence functions over the existing SDK query API.

---

## Non-goals

Do not clone Ecto.

Do not introduce `DTO` as the main domain term.

Do not require Ecto as a dependency.

Do not hide access to raw SurrealQL.

---

## Proposed developer experience

```elixir
defmodule MyApp.Accounts.User do
  use HgsSurrealdbSdk.Schema

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
```

Usage:

```elixir
HgsSurrealdbSdk.Repo.get(client, MyApp.Accounts.User, "user:abc")

HgsSurrealdbSdk.Repo.all(client, MyApp.Accounts.User)

HgsSurrealdbSdk.Repo.find(client, MyApp.Accounts.User, %{email: "jane@example.com"})

HgsSurrealdbSdk.Repo.create(client, MyApp.Accounts.User, %{
  name: "Jane",
  email: "jane@example.com"
})

HgsSurrealdbSdk.Repo.update(client, MyApp.Accounts.User, "user:abc", %{
  age: 42
})

HgsSurrealdbSdk.Repo.delete(client, MyApp.Accounts.User, "user:abc")
```

---

## New module: `HgsSurrealdbSdk.Schema`

Responsibilities:

```elixir
__table__/0
__schema__/0
validate/1
hydrate/1
dump/1
```

Expected behavior:

```elixir
User.__table__()
# "user"

User.validate(params)
# {:ok, validated_map} | {:error, validation_error}

User.hydrate(record)
# {:ok, %User{...}} | {:error, validation_error}

User.dump(%User{})
# {:ok, map} | {:error, validation_error}
```

Schemas should hydrate into structs by default.

---

## New module: `HgsSurrealdbSdk.Repo`

Initial public API:

```elixir
get(client, schema, id, opts \\ [])
all(client, schema, filters \\ %{}, opts \\ [])
find(client, schema, filters, opts \\ [])
create(client, schema, attrs, opts \\ [])
update(client, schema, id, attrs, opts \\ [])
delete(client, schema, id, opts \\ [])
query(client, schema, surql, vars \\ %{}, opts \\ [])
```

Optional follow-up API:

```elixir
find_or_create(client, schema, filters, attrs \\ %{}, opts \\ [])
find_and_update(client, schema, filters, attrs, opts \\ [])
upsert(client, schema, id, attrs, opts \\ [])
```

---

## Query behavior

Use existing SDK calls:

```elixir
HgsSurrealdbSdk.query(client, surql, vars)
```

Do not assume a nonexistent `HgsSurrealdbSdk.use/3` API.

Respect current client namespace/database behavior.

---

## Example generated SurrealQL

### `get`

```sql
SELECT * FROM $id;
```

Vars:

```elixir
%{id: "user:abc"}
```

### `all`

```sql
SELECT * FROM type::table($table);
```

Vars:

```elixir
%{table: "user"}
```

### `find`

```sql
SELECT * FROM type::table($table)
WHERE email = $email
LIMIT 1;
```

### `create`

```sql
CREATE type::table($table) CONTENT $attrs;
```

### `update`

```sql
UPDATE $id MERGE $attrs;
```

### `delete`

```sql
DELETE $id RETURN BEFORE;
```

---

## Filter support, POC scope

Support only simple equality filters first:

```elixir
%{email: "jane@example.com", status: "active"}
```

Later expand to:

```elixir
%{
  age: {:gte, 18},
  name: {:like, "Jane"},
  status: {:in, ["active", "pending"]},
  limit: 10,
  order_by: [desc: :inserted_at]
}
```

---

## Error model

Return SDK-style tuples:

```elixir
{:ok, result}
{:error, %HgsSurrealdbSdk.Error{}}
{:error, %HgsSurrealdbSdk.Schema.ValidationError{}}
```

Add:

```elixir
HgsSurrealdbSdk.Schema.ValidationError
```

It should wrap Zoi validation errors without leaking awkward internals.

---

## Files to add

```text
lib/surreal_db/schema.ex
lib/surreal_db/schema/validation_error.ex
lib/surreal_db/repo.ex
lib/surreal_db/repo/filter_builder.ex
test/surreal_db/schema_test.exs
test/surreal_db/repo_test.exs
test/surreal_db/repo/filter_builder_test.exs
```

---

## Dependency

Add Zoi to `mix.exs`:

```elixir
{:zoi, "~> 0.7"}
```

Current Hex listing shows Zoi `0.7.4`, so Codex should verify the latest compatible version before pinning. ([Hexdocs][3])

---

## Definition of done

Feature is complete when:

1. A schema module can declare `table` and `schema`.
2. Schema modules hydrate validated HgsSurrealdbSdk maps into structs.
3. Invalid data returns structured validation errors.
4. `Repo.get/all/find/create/update/delete` work through existing `HgsSurrealdbSdk.query/3`.
5. Simple equality filters are parameterized, not string-interpolated.
6. Tests cover schema declaration, validation, hydration, dump, query generation, and repo result hydration.
7. Existing SDK tests still pass.

---

## Recommended implementation order

1. Implement `HgsSurrealdbSdk.Schema`.
2. Add Zoi dependency.
3. Implement validation and hydration.
4. Implement `HgsSurrealdbSdk.Repo.FilterBuilder`.
5. Implement `HgsSurrealdbSdk.Repo`.
6. Add tests using mocked/stubbed query behavior.
7. Add one integration-style example module in docs/tests.

The naming should stay **Schema** and **Repo**. “DTO” can remain a use case, not the SDK language.

[1]: https://elixirforum.com/t/zoi-schema-validation-library-inspired-by-zod/72108?utm_source=chatgpt.com "Zoi - schema validation library inspired by Zod - Elixir Forum"
[2]: https://github.com/MikaAK/ecto_shorts/blob/master/lib/ecto_shorts.ex?utm_source=chatgpt.com "ecto_shorts/lib/ecto_shorts.ex at main · MikaAK/ecto_shorts"
[3]: https://hexdocs.pm/zoi/0.7.4/index.html?utm_source=chatgpt.com "Zoi — Zoi v0.7.4"
