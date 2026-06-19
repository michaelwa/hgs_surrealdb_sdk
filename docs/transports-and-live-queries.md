# Transports and Live Queries

The SDK supports HTTP and WebSocket transports for
[SurrealDB](https://surrealdb.com/docs/surrealdb).

## HTTP

HTTP is the default transport:

```elixir
{:ok, client} =
  SurrealDB.connect(
    endpoint: "http://localhost:8000",
    namespace: "test",
    database: "test",
    username: "root",
    password: "root"
  )

{:ok, result} = SurrealDB.query(client, "SELECT * FROM person")
```

## RPC

```elixir
{:ok, response} = SurrealDB.rpc(client, "query", ["SELECT * FROM person"])

IO.inspect(response.result)
```

## WebSocket

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

The WebSocket transport uses [WebSockex](https://hexdocs.pm/websockex) because
it is a maintained Elixir WebSocket client with an OTP-friendly process model.

With `transport: :websocket`, a supervised `SurrealDB.Store` supervises a
self-reconnecting WebSocket connection.

## Live queries

Live queries use the WebSocket message API. Pass the live query explicitly; the
SDK does not rewrite a normal `SELECT` into a live query.

```elixir
{:ok, conn} =
  SurrealDB.connect_ws(
    endpoint: "ws://localhost:8000/rpc",
    namespace: "test",
    database: "test",
    username: "root",
    password: "root"
  )

{:ok, subscription} =
  SurrealDB.live(conn, "LIVE SELECT * FROM person", send_to: self())

receive do
  {:surrealdb_live, "live-person", event} ->
    IO.inspect(event)
end

:ok = SurrealDB.kill(conn, subscription)
```

## Store helpers

A supervised store delegates transport-aware calls:

```elixir
MyApp.SurrealStore.query("SELECT * FROM person")
MyApp.SurrealStore.rpc("query", ["SELECT * FROM person"])
MyApp.SurrealStore.live("LIVE SELECT * FROM person", send_to: self())
MyApp.SurrealStore.kill(subscription)
```
