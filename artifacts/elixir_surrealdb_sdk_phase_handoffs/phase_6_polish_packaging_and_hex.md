# Codex Handoff — Phase 6: Polish, Packaging, and Hex Readiness

## Project

Elixir-native SDK for SurrealDB.

## Prerequisites

Core functionality should already exist:

- HTTP query execution
- CRUD helpers
- RPC abstraction
- WebSocket transport
- live-query support, if completed

## Phase Goal

Prepare the SDK for real-world use and eventual Hex publication.

This phase is about quality, documentation, consistency, and release hygiene.

## Scope

Implement or improve:

- package metadata
- docs
- examples
- typespecs
- Dialyzer friendliness
- CI workflow
- formatter config
- changelog
- license
- contribution guide
- integration test documentation
- version compatibility notes

## Non-Goals

Do not add major new SDK features in this phase.

Avoid:

- schema layer
- migrations
- query DSL
- Phoenix integrations
- connection pooling

This is a stabilization phase.

## Mix Project Metadata

Ensure `mix.exs` includes:

- app name
- version
- description
- package metadata
- docs metadata
- source URL placeholder
- licenses
- links

Example package metadata shape:

```elixir
defp package do
  [
    licenses: ["MIT"],
    links: %{
      "GitHub" => "https://github.com/YOUR_ORG/elixir_surrealdb_sdk"
    }
  ]
end
```

Do not publish to Hex automatically.

## Documentation

Improve:

```text
README.md
CHANGELOG.md
LICENSE
CONTRIBUTING.md
docs/
  getting-started.md
  configuration.md
  querying.md
  crud.md
  websocket.md
  live-queries.md
  testing.md
```

README should include:

- project status
- installation
- basic HTTP query example
- CRUD example
- WebSocket example
- live query example, if implemented
- error handling example
- compatibility notes
- local SurrealDB test setup

## Typespecs

Add typespecs for public functions:

```elixir
@spec connect(keyword()) :: {:ok, SurrealDB.Client.t()} | {:error, SurrealDB.Error.t()}
@spec query(client_or_connection, String.t(), map()) ::
        {:ok, SurrealDB.QueryResult.t()} | {:error, SurrealDB.Error.t()}
```

Add `@type t` declarations to structs.

## Examples

Add or improve:

```text
examples/basic_query.exs
examples/crud.exs
examples/websocket_query.exs
examples/live_query.exs
```

Each example should be small and runnable.

## Testing

Add clear test categories:

```text
unit tests
integration tests requiring local SurrealDB
```

If integration tests need a local SurrealDB instance, make them opt-in:

```bash
RUN_INTEGRATION=true mix test
```

Document a Docker command for local SurrealDB if appropriate.

## CI

Add a GitHub Actions workflow:

```text
.github/workflows/ci.yml
```

It should run:

```bash
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

Optionally add Dialyzer later. Do not make Dialyzer block CI unless it is configured cleanly.

## Error Model Review

Review all public functions and make sure they consistently return:

```elixir
{:ok, value}
{:error, %SurrealDB.Error{}}
```

or documented exceptions only where truly exceptional.

## Naming Review

Ensure module names are consistent:

```text
SurrealDB
SurrealDB.Client
SurrealDB.Config
SurrealDB.Error
SurrealDB.QueryResult
SurrealDB.RPC
SurrealDB.Transport.HTTP
SurrealDB.Transport.WebSocket
SurrealDB.Live
```

If the project currently uses mixed naming, normalize it carefully.

## Definition of Done

Phase 6 is complete when:

- docs are coherent
- README is useful to a new user
- package metadata is ready
- typespecs exist for public functions
- examples are present
- tests pass
- CI workflow exists
- no major new features were added
- project is close to Hex-ready but not automatically published
