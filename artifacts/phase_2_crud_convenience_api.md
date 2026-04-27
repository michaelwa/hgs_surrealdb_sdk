# Codex Handoff — Phase 2: CRUD Convenience API

## Project

Elixir-native SDK for SurrealDB.

## Prerequisite

Phase 1 must already be complete:

- Mix project exists
- HTTP query execution works
- `SurrealDB.connect/1` works
- `SurrealDB.query/2` or `SurrealDB.query/3` works
- Structured error handling exists

## Phase Goal

Add ergonomic CRUD convenience functions on top of the existing query/HTTP layer.

The goal is to make simple SurrealDB operations feel natural in Elixir without adding an ORM or schema layer.

## Scope

Implement public functions such as:

```elixir
SurrealDB.select(client, "person")
SurrealDB.select(client, "person:john")

SurrealDB.create(client, "person", %{name: "John"})
SurrealDB.create(client, "person:john", %{name: "John"})

SurrealDB.update(client, "person:john", %{name: "John Doe"})
SurrealDB.merge(client, "person:john", %{active: true})
SurrealDB.patch(client, "person:john", [%{op: "replace", path: "/name", value: "Jane"}])
SurrealDB.delete(client, "person:john")
```

Use existing Phase 1 transport and result/error conventions.

## Non-Goals

Do not implement:

- WebSocket transport
- Live queries
- Full RPC abstraction
- Ecto-style changesets
- Schema modules
- Migrations
- Query builder DSL
- Compile-time table definitions

## Public API Requirements

All public functions should return:

```elixir
{:ok, %SurrealDB.QueryResult{}}
{:error, %SurrealDB.Error{}}
```

or another already-established Phase 1 result shape.

Do not introduce a second error convention.

## Implementation Strategy

Prefer implementing CRUD helpers by generating SurrealQL and delegating to `SurrealDB.query/2` or `SurrealDB.query/3`.

Example:

```elixir
def select(client, thing) do
  query(client, "SELECT * FROM #{thing}")
end
```

However, avoid unsafe interpolation where user values are involved.

For record/table identifiers, add a small helper that validates simple identifiers before interpolation.

For data payloads, prefer query variables if available from Phase 1. If query variables were not completed in Phase 1, add variable support before implementing `create`, `update`, and `merge`.

## Identifier Safety

Add a helper module if useful:

```elixir
SurrealDB.Identifier
```

It should validate or normalize:

- table names, e.g. `"person"`
- record IDs, e.g. `"person:john"`

Keep this simple. Do not build a full SurrealQL parser.

## Suggested Function Semantics

### `select/2`

```elixir
SurrealDB.select(client, "person")
SurrealDB.select(client, "person:john")
```

Should produce a SurrealQL select query.

### `create/3`

```elixir
SurrealDB.create(client, "person", %{name: "John"})
SurrealDB.create(client, "person:john", %{name: "John"})
```

Should create a table record or specific record ID.

### `update/3`

```elixir
SurrealDB.update(client, "person:john", %{name: "John Doe"})
```

Should replace the target record.

### `merge/3`

```elixir
SurrealDB.merge(client, "person:john", %{active: true})
```

Should merge the supplied fields into the target record.

### `patch/3`

```elixir
SurrealDB.patch(client, "person:john", [%{op: "replace", path: "/name", value: "Jane"}])
```

Should support SurrealDB patch behavior if available through SurrealQL or HTTP API. If not cleanly supported yet, document as deferred and do not fake behavior.

### `delete/2`

```elixir
SurrealDB.delete(client, "person:john")
```

Should delete the target record.

## Tests

Add tests for:

- `select/2` table query generation
- `select/2` record query generation
- `create/3` delegates with data safely
- `update/3` delegates with data safely
- `merge/3` delegates with data safely
- `delete/2` query generation
- invalid identifiers return `%SurrealDB.Error{type: :invalid_identifier}`
- CRUD functions preserve existing error style

## Documentation

Update `README.md` with a CRUD section:

```elixir
{:ok, _} = SurrealDB.create(client, "person", %{name: "Jane"})
{:ok, people} = SurrealDB.select(client, "person")
{:ok, _} = SurrealDB.merge(client, "person:jane", %{active: true})
{:ok, _} = SurrealDB.delete(client, "person:jane")
```

## Definition of Done

Phase 2 is complete when:

- CRUD helpers are implemented
- all helpers delegate through the existing transport/query layer
- tests cover success and invalid input paths
- no WebSocket or live-query functionality has been added
- `mix format` has been run
- `mix test` passes
- README documents CRUD usage
