# Codex Handoff — Phase 5: Live Queries

## Project

Elixir-native SDK for SurrealDB.

## Prerequisites

Phases 1 through 4 must already be complete:

- HTTP query execution exists
- CRUD helpers exist
- RPC abstraction exists
- WebSocket transport exists
- WebSocket request/response routing works

## Phase Goal

Add live-query support using the WebSocket transport.

This phase should allow callers to subscribe to changes from SurrealDB and receive events through an Elixir-friendly interface.

## Scope

Implement:

- live query start
- live query kill/stop
- event routing
- callback or message-based subscription API
- subscription registry
- tests for event routing
- README examples

## Non-Goals

Do not implement:

- Phoenix LiveView components
- Phoenix PubSub integration
- advanced reconnect/resubscribe
- durable subscription recovery
- backpressure framework
- full reactive query DSL

These can be added in later phases.

## Suggested Public API Options

Pick one primary API and document it clearly.

### Option A: Callback API

```elixir
{:ok, subscription} =
  SurrealDB.live(conn, "SELECT * FROM person", fn event ->
    IO.inspect(event, label: "person changed")
  end)

:ok = SurrealDB.kill(conn, subscription)
```

### Option B: Message API

```elixir
{:ok, subscription} =
  SurrealDB.live(conn, "SELECT * FROM person", send_to: self())

receive do
  {:surrealdb_live, ^subscription, event} ->
    IO.inspect(event)
end

:ok = SurrealDB.kill(conn, subscription)
```

### Recommendation

Prefer the message API first because it fits OTP and is easier to test.

The callback API can be added as a convenience wrapper later.

## Suggested Modules

```text
SurrealDB.Live
SurrealDB.Live.Subscription
SurrealDB.Live.Event
```

Possible struct:

```elixir
defmodule SurrealDB.Live.Subscription do
  defstruct [
    :id,
    :query,
    :target,
    :status
  ]
end
```

Event struct:

```elixir
defmodule SurrealDB.Live.Event do
  defstruct [
    :subscription_id,
    :action,
    :result,
    :raw
  ]
end
```

## Connection Process Changes

The WebSocket connection process now needs to route two kinds of incoming messages:

1. RPC responses to pending request callers
2. Live query events to subscription targets

Suggested state addition:

```elixir
%{
  subscriptions: %{
    live_query_id => target
  }
}
```

Where `target` may be:

```elixir
{:pid, pid}
{:callback, fun}
```

If only implementing message API, keep target as a PID.

## Live Query Lifecycle

### Start

```text
SurrealDB.live(conn, query, opts)
  -> send live query RPC/request
  -> receive live query ID
  -> store subscription mapping
  -> return {:ok, %Subscription{}}
```

### Event

```text
incoming WebSocket event
  -> decode
  -> identify live query ID
  -> build %SurrealDB.Live.Event{}
  -> send to target PID
```

### Kill

```text
SurrealDB.kill(conn, subscription)
  -> send kill RPC/request
  -> remove subscription mapping
  -> return :ok or {:error, error}
```

## Error Handling

Use `%SurrealDB.Error{}`.

Suggested types:

```elixir
:live_query_error
:subscription_not_found
:live_event_decode_error
:websocket_closed
```

## Tests

Add tests for:

- live query start stores subscription
- live query start returns subscription struct
- incoming live event routes to subscribed PID
- unknown subscription event is handled safely
- kill removes subscription
- kill of missing subscription returns error
- malformed live event returns/logs structured error behavior
- existing WebSocket RPC tests still pass

## Documentation

Add README section:

```elixir
{:ok, conn} = SurrealDB.connect_ws(...)

{:ok, sub} =
  SurrealDB.live(conn, "LIVE SELECT * FROM person", send_to: self())

receive do
  {:surrealdb_live, ^sub, event} ->
    IO.inspect(event)
end

:ok = SurrealDB.kill(conn, sub)
```

Document whether the SDK expects the caller to include `LIVE SELECT` or whether the SDK wraps a normal query. Prefer explicitness:

```elixir
SurrealDB.live(conn, "LIVE SELECT * FROM person", send_to: self())
```

## Definition of Done

Phase 5 is complete when:

- live query subscriptions work over WebSocket
- events route to subscriber processes
- subscriptions can be killed
- tests cover subscription lifecycle and routing
- existing query/CRUD/RPC/WebSocket tests still pass
- README includes live-query example
- no Phoenix-specific integration is added
