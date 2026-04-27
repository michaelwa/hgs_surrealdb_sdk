# Codex Handoff — Phase 4: WebSocket Transport

## Project

Elixir-native SDK for SurrealDB.

## Prerequisites

Phases 1 through 3 must already be complete:

- HTTP query execution exists
- CRUD helpers exist
- RPC abstraction exists
- request/response/error conventions exist

## Phase Goal

Add a WebSocket transport for SurrealDB RPC calls.

This phase should introduce a process-backed connection capable of sending RPC requests, receiving responses, matching responses by request ID, and returning results to callers.

## Scope

Implement:

- `SurrealDB.WebSocket`
- `SurrealDB.WebSocket.Connection`
- `SurrealDB.Transport.WebSocket`
- connection start/stop
- RPC request send
- RPC response receive
- pending request tracking by request ID
- timeout handling
- basic authentication/use namespace/use database setup over WebSocket, if required by SurrealDB protocol
- tests for message routing and timeouts

## Non-Goals

Do not implement:

- Live query event subscriptions
- Phoenix PubSub integration
- automatic reconnect
- connection pooling
- supervision tree helpers beyond what is needed for tests/examples
- advanced telemetry
- backpressure system

Those can be added later.

## Suggested Public API

Add an explicit WebSocket connect function rather than changing existing behavior implicitly:

```elixir
{:ok, conn} =
  SurrealDB.connect_ws(
    endpoint: "ws://localhost:8000/rpc",
    namespace: "test",
    database: "test",
    username: "root",
    password: "root"
  )

{:ok, result} = SurrealDB.query(conn, "SELECT * FROM person")
```

Alternatively, allow:

```elixir
SurrealDB.connect(
  endpoint: "ws://localhost:8000/rpc",
  transport: :websocket,
  namespace: "test",
  database: "test",
  username: "root",
  password: "root"
)
```

Prefer the smallest change that fits the existing design.

## Dependency Guidance

Use a stable Elixir WebSocket client library.

Before adding the dependency, inspect current ecosystem options and choose one that:

- is actively maintained
- works cleanly with OTP processes
- supports client WebSocket connections
- is simple enough for SDK use

Document why the dependency was chosen.

## Process Design

A WebSocket connection process should:

- own the socket
- keep a map of pending requests
- send encoded RPC JSON messages
- receive decoded responses
- match response `id` to the waiting caller
- return timeout errors for unanswered requests

Suggested state:

```elixir
%{
  socket: socket,
  client: client,
  pending: %{
    request_id => from
  }
}
```

Use `GenServer` if appropriate.

## RPC Flow

Expected call flow:

```text
SurrealDB.query(conn, sql)
  -> SurrealDB.RPC.call(conn, "query", [sql])
  -> SurrealDB.Transport.WebSocket.call(conn, request)
  -> WebSocket process sends JSON
  -> response arrives
  -> response ID matches pending request
  -> caller receives {:ok, response}
```

## Error Handling

Use the existing `%SurrealDB.Error{}` struct.

Add or reuse types:

```elixir
:websocket_connect_error
:websocket_send_error
:websocket_closed
:websocket_timeout
:rpc_error
:unexpected_response
```

## Tests

Add tests for:

- starting a WebSocket connection process
- request ID generation and pending tracking
- matching responses to callers
- timeout behavior
- socket close behavior
- RPC error response mapping
- existing HTTP behavior still works

Where live SurrealDB is impractical in unit tests, isolate the connection logic and test message handling directly.

## Documentation

Update README with:

```elixir
{:ok, conn} =
  SurrealDB.connect_ws(
    endpoint: "ws://localhost:8000/rpc",
    namespace: "test",
    database: "test",
    username: "root",
    password: "root"
  )

{:ok, result} = SurrealDB.query(conn, "SELECT * FROM person")
```

Add notes that WebSocket transport is useful for persistent RPC and future live-query support.

## Definition of Done

Phase 4 is complete when:

- WebSocket transport exists
- RPC requests can be sent over WebSocket
- responses are matched to request IDs
- timeouts are handled
- HTTP transport still works
- tests pass
- README documents WebSocket usage
- live queries are still deferred
