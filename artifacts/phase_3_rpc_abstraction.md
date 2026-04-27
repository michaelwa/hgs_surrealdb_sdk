# Codex Handoff — Phase 3: RPC Abstraction

## Project

Elixir-native SDK for SurrealDB.

## Prerequisites

Phase 1 and Phase 2 must already be complete:

- HTTP query execution exists
- CRUD helpers exist
- structured error/result conventions exist
- public API is stable

## Phase Goal

Introduce a transport-neutral RPC abstraction that can support both HTTP RPC and future WebSocket RPC.

This phase is not about WebSockets yet. It is about creating the internal shape that makes WebSockets possible later without rewriting the public API.

## Scope

Implement:

- `SurrealDB.RPC`
- `SurrealDB.RPC.Request`
- `SurrealDB.RPC.Response`
- `SurrealDB.Transport` behavior, if useful
- HTTP-backed RPC call path
- Tests for RPC request/response handling

## Non-Goals

Do not implement:

- WebSocket transport
- Live queries
- Reconnect logic
- Subscription routing
- GenServer connection process
- PubSub
- Phoenix integrations

## Suggested API

Internal API:

```elixir
SurrealDB.RPC.call(client, "query", ["SELECT * FROM person"])
```

Optional public API, if it does not destabilize the current API:

```elixir
SurrealDB.rpc(client, "query", ["SELECT * FROM person"])
```

Keep this lower-level than `SurrealDB.query/2`.

## Design Intent

The SDK should support this future shape:

```text
SurrealDB.query/2
  -> SurrealDB.RPC.call/3
    -> SurrealDB.Transport.HTTP.call/2
    -> SurrealDB.Transport.WebSocket.call/2
```

But in this phase, only HTTP-backed RPC should be implemented.

## Request Structure

Suggested struct:

```elixir
defmodule SurrealDB.RPC.Request do
  defstruct [
    :id,
    :method,
    params: []
  ]
end
```

IDs can be generated using `System.unique_integer/1` or another simple mechanism.

Do not add a UUID dependency unless necessary.

## Response Structure

Suggested struct:

```elixir
defmodule SurrealDB.RPC.Response do
  defstruct [
    :id,
    :result,
    :error,
    :raw
  ]
end
```

## Error Handling

Map RPC errors into the existing `%SurrealDB.Error{}` struct.

Suggested types:

```elixir
:rpc_error
:rpc_decode_error
:rpc_unexpected_response
:transport_error
```

Do not introduce exceptions for normal RPC failures.

## Compatibility with Existing Public API

Existing calls should keep working:

```elixir
SurrealDB.query(client, "SELECT * FROM person")
SurrealDB.select(client, "person")
SurrealDB.create(client, "person", %{name: "Jane"})
```

If practical, migrate internals so `query/2` uses the new RPC layer. If that creates too much churn, leave the existing HTTP query path in place and add RPC as a parallel internal capability.

Favor minimal disruption over purity.

## Tests

Add tests for:

- RPC request struct creation
- RPC request encoding
- RPC response decoding
- RPC success response mapping
- RPC error response mapping
- HTTP transport failure mapping
- request IDs are present
- existing Phase 1 and Phase 2 tests still pass

## Documentation

Update architecture documentation with:

```text
Public API
  -> Query/CRUD functions
  -> RPC abstraction
  -> Transport implementation
```

Add a short README section:

```elixir
{:ok, response} = SurrealDB.rpc(client, "query", ["SELECT * FROM person"])
```

Only expose this if you decide `SurrealDB.rpc/3` is stable enough.

## Definition of Done

Phase 3 is complete when:

- RPC request/response modules exist
- HTTP-backed RPC call path exists
- existing public API still works
- tests cover RPC success/error paths
- WebSocket was not implemented
- live queries were not implemented
- `mix format` has been run
- `mix test` passes
