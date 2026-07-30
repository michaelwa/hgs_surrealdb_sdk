# Deterministic WebSocket Readiness

**Date:** 2026-07-30  
**Status:** Approved (design), pending implementation  
**Roadmap item:** `ROADMAP.md` — “P0 — Deterministic WebSocket readiness”

## 1. Problem

`SurrealDB.connect_ws/1` currently returns as soon as the WebSocket connection
process is started. The process performs authentication and namespace/database
selection afterward, so an immediate query can receive
`"websocket connection not ready"`. Consumers have no reliable readiness
contract, and the integration helper currently reaches into GenServer state and
polls `setup_complete?` to compensate.

The same `SurrealDB.WebSocket.Connection` process is also used by supervised
stores. A store must be able to start while SurrealDB is unavailable and keep
reconnecting in the background, so making every WebSocket start synchronous
would break the store’s lifecycle contract.

## 2. Goals and non-goals

### Goals

- Make a successful `SurrealDB.connect_ws/1` return only after initial setup is
  complete.
- Treat the configured WebSocket timeout as one overall deadline covering the
  socket connection, authentication, and namespace/database selection.
- Return authentication and `USE` failures from `connect_ws/1` as structured
  `SurrealDB.Error` values.
- Return a deterministic timeout error when setup does not complete before the
  deadline.
- Preserve asynchronous startup and reconnect behavior for supervised stores.
- Remove the need for normal client tests or documentation to poll internal
  connection state.
- Keep post-readiness RPC and live-query behavior unchanged.

### Non-goals

- Re-registering live queries after reconnect; that is the separate P0 roadmap
  item for WebSocket reconnect and live-query recovery.
- Changing reconnect backoff, telemetry event names, or retry policy.
- Queuing arbitrary user RPC calls while a direct connection is becoming ready.
- Adding a new public `ready?/1` or `wait_for_setup/1` API.
- Changing the default timeout value, currently 5 seconds.

## 3. Public contract

### Direct clients

`SurrealDB.connect_ws/1` and `SurrealDB.WebSocket.connect/2` use the configured
WebSocket timeout as an overall startup deadline. For a direct client:

```elixir
{:ok, client} =
  SurrealDB.connect_ws(
    endpoint: "ws://localhost:8000/rpc",
    namespace: "app",
    database: "app",
    username: "root",
    password: "root",
    websocket_options: [timeout: 5_000]
  )

{:ok, result} = SurrealDB.query(client, "SELECT * FROM person")
```

The query above is valid immediately after `connect_ws/1` returns `{:ok,
client}`. The client is not exposed as ready before all configured setup steps
have succeeded.

The setup sequence is:

1. Establish the WebSocket.
2. Send `signin` for basic authentication, `authenticate` for bearer
   authentication, or no authentication request for anonymous clients.
3. Send `use` with the configured namespace and database.
4. Mark the connection ready and return the client.

If any step fails, `connect_ws/1` returns `{:error, %SurrealDB.Error{}}` and
does not return a usable client. The error preserves the existing error type,
code, message, and raw response where available. Authentication and `USE`
failures must not be collapsed into a generic “not ready” error.

If the overall deadline expires, `connect_ws/1` returns:

```elixir
{:error, %SurrealDB.Error{type: :websocket_timeout}}
```

The direct connection process and socket are stopped after a startup timeout or
setup failure so a failed `connect_ws/1` call cannot leave an unowned process
running in the background.

### Supervised stores

`SurrealDB.Store.Supervisor` continues to force `reconnect: true` for WebSocket
stores. Store startup remains successful when the socket or initial setup is
unavailable; the connection process retries asynchronously using the existing
reconnect behavior. Store calls made while setup is incomplete continue to
return the existing structured `:websocket_connect_error` not-ready error.

Once a store connection completes setup, calls proceed normally. A later
disconnect continues to clear readiness, fail pending callers, emit existing
connection telemetry, and schedule reconnect.

The direct-client readiness wait must therefore be opt-in at the connection
boundary, not a global requirement that makes all connection processes block
their supervisors during startup.

## 4. Runtime design

### 4.1 Setup as explicit connection state

Refactor `SurrealDB.WebSocket.Connection` so initial setup is represented by
explicit state rather than a blocking `receive` inside `handle_info`. The
connection keeps the existing GenServer ownership of the socket and user RPCs,
but tracks setup separately from ordinary pending RPC calls.

The setup state should contain:

- the current setup phase (`:connecting`, `:authenticating`, `:selecting`, or
  `:ready`),
- the absolute monotonic deadline for the current initial/reconnect setup,
- the internal request ID currently awaiting a setup response, and
- a direct-client readiness waiter when one exists.

Setup responses are consumed by the normal WebSocket frame handler and matched
to the internal setup request ID. A successful authentication response advances
to `use`; a successful `use` response transitions to `:ready`. User RPCs remain
rejected until that transition.

The implementation may use an internal readiness message or a GenServer waiter
to notify `SurrealDB.WebSocket.connect/2`, but the public behavior must not
expose the state structure or require callers to inspect it.

### 4.2 Overall deadline

At the beginning of a setup attempt, calculate one deadline with
`System.monotonic_time(:millisecond) + timeout`. Before sending or waiting for
each setup step, calculate the remaining time from that deadline.

For example, with `timeout: 5_000`:

- socket establishment, authentication, and `USE` together have at most 5
  seconds;
- if authentication consumes 3 seconds, `USE` has at most 2 seconds left;
- a non-positive remaining duration immediately produces
  `:websocket_timeout`.

The deadline is per setup attempt. A supervised reconnect gets a fresh timeout
budget when that reconnect begins; it does not inherit the original startup
deadline.

The timeout option remains located at `websocket_options: [timeout: value]`
and retains the current default of 5 seconds. This item does not redesign
timeout-option validation; it defines the deadline semantics for the positive
timeout values currently used by the SDK.

### 4.3 Direct connection lifecycle

For a non-reconnecting client, `SurrealDB.WebSocket.connect/2` starts the
connection and waits for one of five outcomes:

| Outcome | Result |
| --- | --- |
| Socket and setup succeed before deadline | `{:ok, client}` |
| Setup returns an RPC/authentication/`USE` error | `{:error, original_error}` |
| Deadline expires | `{:error, %Error{type: :websocket_timeout}}` |
| Socket closes before setup completes | `{:error, %Error{type: :websocket_closed}}` |
| Socket cannot be started | `{:error, %Error{type: :websocket_connect_error}}` |

The wait must be bounded by the same overall deadline. If the caller-side wait
expires due to scheduling or a race, it must stop the direct connection before
returning the timeout error.

### 4.4 Supervised store lifecycle

For a reconnecting store, a socket-connected event starts the same setup state
machine without a caller wait. Setup success emits the existing `:connected`
telemetry event and marks the state ready. Setup failure follows the existing
reconnect policy:

- a closed socket schedules reconnect;
- an authentication or `USE` error stops the current connection process, which
  the store supervisor may restart according to its existing child policy;
- a setup timeout closes the socket and schedules reconnect.

The implementation must not emit `:connected` before authentication and `USE`
have succeeded. It must not make `SurrealDB.Store.Supervisor.start_link/3`
wait for setup.

## 5. Error and telemetry semantics

Existing error types and fields remain the compatibility baseline:

- authentication or `USE` RPC failures remain `:rpc_error` with their server
  code/message/raw payload;
- setup timeout is `:websocket_timeout`;
- socket closure is `:websocket_closed`;
- socket startup failure is `:websocket_connect_error`.

Direct setup failure is returned to the caller and should not be reported as a
successful connection. Existing lifecycle telemetry must continue to describe
actual state transitions: `:connected` only after setup, and
`:disconnected`/`:reconnecting` according to the existing reconnect path.
Credentials and variable values must not be added to error metadata or
telemetry.

## 6. Test design

### Unit tests

Extend `test/surreal_db/web_socket_test.exs` and the fake socket support to
cover:

1. `SurrealDB.connect_ws/1` returns only after fake `signin` and `use`
   responses, and an immediate `SurrealDB.query/2` is dispatched successfully.
2. Basic-authentication failure is returned from `connect_ws/1` with the
   server error preserved.
3. Bearer-authentication failure is returned from `connect_ws/1` with the
   server error preserved.
4. `USE` failure is returned from `connect_ws/1` with the server error
   preserved.
5. No setup response causes one overall timeout, not one timeout per setup
   request. The test should use a short timeout and assert elapsed time stays
   within a tolerant range around that single budget.
6. Socket closure during setup returns `:websocket_closed` and does not leave
   the direct connection process alive.
7. A reconnecting connection still starts asynchronously, reports not-ready
   behavior while setup is pending, and becomes usable after setup succeeds.
8. A reconnecting setup timeout schedules another attempt rather than making
   store startup fail.

The fake socket should gain deterministic controls for setup responses and
delays. Tests must drive frames explicitly or use bounded messages; they must
not sleep until the process happens to be ready or inspect `setup_complete?` to
verify the direct-client contract.

### Integration tests

Update `test/support/integration_case.ex` so `integration_ws_client/0` relies
on the `SurrealDB.connect_ws/1` contract and removes `await_ws_ready/0` and its
polling implementation. The WebSocket integration test should issue its first
RPC immediately after `connect_ws/1` returns.

The integration harness should retain a bounded WebSocket timeout so a server
that accepts the socket but never completes setup fails with a useful
structured error rather than hanging the suite.

## 7. Documentation

Update `docs/transports-and-live-queries.md` to state that a successful direct
`SurrealDB.connect_ws/1` has completed authentication and namespace/database
selection, and that the configured WebSocket timeout is the overall startup
deadline. Document the returned error categories at a concise level.

Document the distinction between direct clients and supervised stores:

- direct clients fail from `connect_ws/1` when startup setup cannot complete;
- supervised stores start/reconnect asynchronously and calls may return a
  temporary not-ready error while reconnecting.

Update any test-facing or troubleshooting text that describes the old polling
workaround. No new public readiness helper should be documented.

## 8. Acceptance criteria mapping

| Roadmap criterion | Design coverage |
| --- | --- |
| Successful `connect_ws/1` client can issue its first query immediately | Sections 3 and 6 |
| Authentication and `USE` failures return from `connect_ws/1` | Sections 3, 4.3, and 6 |
| Startup timeout is documented and tested | Sections 4.2, 4.3, 6, and 7 |
| Store startup remains compatible with supervisor reconnect | Sections 3, 4.4, and 6 |
| No undocumented readiness polling for normal client usage | Sections 3, 6, and 7 |

## 9. Scope and implementation boundaries

Expected implementation files are:

- `lib/surreal_db/web_socket/connection.ex` — explicit setup state,
  deadline handling, direct readiness notification, and reconnect behavior;
- `lib/surreal_db/web_socket.ex` — direct connection wait/error cleanup;
- `lib/surreal_db.ex` — only if public option or typespec documentation needs
  clarification;
- `test/support/fake_socket.ex` — deterministic setup response controls;
- `test/surreal_db/web_socket_test.exs` — direct and reconnecting readiness
  coverage;
- `test/support/integration_case.ex` and relevant integration tests — remove
  polling workaround and assert immediate use;
- `docs/transports-and-live-queries.md` — public contract documentation.

Do not combine this work with live-query re-registration, exponential backoff,
or broad WebSocket refactoring unrelated to startup readiness.
