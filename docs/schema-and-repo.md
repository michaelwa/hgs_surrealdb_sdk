# Schemas and Repo

`SurrealDB.Schema` defines table-backed structs with validation powered by
[Zoi](https://hexdocs.pm/zoi). `SurrealDB.Repo` persists those structs through
parameterized SurrealQL and hydrates query results back into schema structs.

## Define a schema

```elixir
defmodule MyApp.User do
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
```

A schema module gets:

- A struct with one field per key in the `Zoi.object/1` map.
- `__table__/0`
- `__schema__/0`
- `validate/1`
- `hydrate/1`
- `dump/1`

The `schema do ... end` block must contain a `Zoi.object(%{...})` with a
literal field map. Struct fields are read from that map at compile time.

## Use a supervised store

With a store module configured and supervised:

```elixir
{:ok, user} =
  MyApp.SurrealStore.create(MyApp.User, %{
    name: "Jane",
    email: "jane@example.com",
    age: 36
  })

{:ok, same_user} = MyApp.SurrealStore.get(MyApp.User, user.id)
{:ok, users} = MyApp.SurrealStore.all(MyApp.User)
{:ok, jane} = MyApp.SurrealStore.find(MyApp.User, %{email: "jane@example.com"})
{:ok, updated} = MyApp.SurrealStore.update(MyApp.User, user.id, %{age: 37})
{:ok, deleted} = MyApp.SurrealStore.delete(MyApp.User, user.id)
```

## Use an explicit client

```elixir
{:ok, client} =
  SurrealDB.connect(
    endpoint: "http://localhost:8000",
    namespace: "app",
    database: "app",
    username: "root",
    password: "root"
  )

{:ok, %MyApp.User{} = user} =
  SurrealDB.Repo.create(client, MyApp.User, %{
    name: "Jane",
    email: "jane@example.com"
  })

{:ok, %MyApp.User{}} = SurrealDB.Repo.get(client, MyApp.User, user.id)
{:ok, [%MyApp.User{}]} = SurrealDB.Repo.all(client, MyApp.User)
{:ok, %MyApp.User{}} = SurrealDB.Repo.find(client, MyApp.User, %{email: "jane@example.com"})
{:ok, %MyApp.User{}} = SurrealDB.Repo.update(client, MyApp.User, user.id, %{age: 37})
{:ok, %MyApp.User{}} = SurrealDB.Repo.delete(client, MyApp.User, user.id)
```

## Raw schema queries

Use `SurrealDB.Repo.query/5` or `Store.query/4` when you need raw SurrealQL but
still want results hydrated into schema structs:

```elixir
{:ok, users} =
  SurrealDB.Repo.query(
    client,
    MyApp.User,
    "SELECT * FROM type::table($table) WHERE age >= $age",
    %{table: "user", age: 21}
  )
```

## Plain CRUD helpers

If you do not need schemas, use the lower-level CRUD helpers:

```elixir
{:ok, _} = SurrealDB.create(client, "person", %{name: "Jane"})
{:ok, people} = SurrealDB.select(client, "person")
{:ok, _} = SurrealDB.merge(client, "person:jane", %{active: true})
{:ok, _} = SurrealDB.delete(client, "person:jane")
```

## Errors

Invalid schema data returns:

```elixir
{:error, %SurrealDB.Schema.ValidationError{}}
```

Connection, auth, identifier, and query failures return:

```elixir
{:error, %SurrealDB.Error{}}
```

Record ids used by `get`, `update`, and `delete` are validated before they are
interpolated as SurrealDB record identifiers. Invalid ids return
`{:error, %SurrealDB.Error{type: :invalid_identifier}}`.

Current Repo filtering supports simple equality filters. Use raw SurrealQL for
more complex queries.
