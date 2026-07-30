# Deterministic WebSocket Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make direct WebSocket clients ready before `connect_ws/1` returns, using one overall setup deadline while preserving asynchronous supervised-store reconnects.

**Architecture:** Replace the blocking setup receive in `SurrealDB.WebSocket.Connection` with an explicit setup state machine that tracks the current phase, internal setup request, and monotonic deadline. Direct connections register a readiness waiter and `SurrealDB.WebSocket.connect/2` waits for setup completion; reconnecting store connections run the same state machine without a waiter and continue retrying asynchronously.

**Tech Stack:** Elixir 1.19, OTP `GenServer`, ExUnit, Jason, Telemetry, WebSockex-compatible socket behavior, existing fake WebSocket test socket, Docker-backed integration suite.

## Global Constraints

- The configured `websocket_options: [timeout: value]` is one overall deadline for socket setup, authentication, and namespace/database selection.
- The default WebSocket timeout remains 5 seconds.
- A successful direct `SurrealDB.connect_ws/1` client can issue its first query immediately.
- Authentication and `USE` failures preserve their existing structured `%SurrealDB.Error{}` values.
- Supervised stores continue to start and reconnect asynchronously with `reconnect: true`.
- Do not add a public `ready?/1` or `wait_for_setup/1` API.
- Do not implement live-query re-registration, exponential backoff, or unrelated WebSocket refactoring.
- Every implementation task ends with a focused test command and an intentional commit.

---

## File map

- Modify `lib/surreal_db/web_socket/connection.ex`: replace blocking setup receives with explicit setup phases, deadlines, internal setup response routing, direct readiness waiting, and reconnect timeout handling.
- Modify `lib/surreal_db/web_socket.ex`: wait for direct readiness, translate startup exits/timeouts to structured errors, and stop failed direct connections.
- Modify `test/support/fake_socket.ex`: add deterministic setup response/error/delay controls while retaining existing `auto_setup: true` behavior.
- Modify `test/surreal_db/web_socket_test.exs`: add direct readiness/error/timeout tests and retain reconnect lifecycle coverage without direct setup polling.
- Modify `test/support/integration_case.ex`: remove `await_ws_ready/0` and the `:sys.get_state/1` polling workaround.
- Modify `test/integration/web_socket_integration_test.exs`: issue the first RPC immediately after `connect_ws/1` returns and assert the immediate real-server round trip.
- Modify `docs/transports-and-live-queries.md`: document direct-client readiness, the overall startup deadline, and the asynchronous store distinction.

### Task 1: Add deterministic fake-socket controls and failing direct-client tests

**Files:**
- Modify: `test/support/fake_socket.ex`
- Modify: `test/surreal_db/web_socket_test.exs`

**Interfaces:**
- `FakeSocket.start_link/4` continues accepting `auto_setup: true` and sends successful responses for `signin`, `authenticate`, and `use` exactly as it does today.
- Add optional `setup_responses: %{optional(String.t()) => {:ok, term()} | {:error, map()}}`; when `auto_setup: true`, a matching method uses the configured response instead of the default success response.
- Add optional `setup_delays: %{optional(String.t()) => non_neg_integer()}`; when configured, the fake socket sends that setup response after the specified delay.
- Existing non-setup frames remain observable through `{:socket_sent, owner, payload}` and receive no automatic response.

- [ ] **Step 1: Extend the fake socket with response overrides.**

  In `start_link/4`, read `setup_responses = Keyword.get(options, :setup_responses, %{})` and `setup_delays = Keyword.get(options, :setup_delays, %{})`. In the `{:send_text, payload}` branch, decode the method and, only when `auto_setup` is true and the method is one of `"signin"`, `"authenticate"`, or `"use"`, send a response using this exact mapping:

  ```elixir
  case Map.get(setup_responses, method, {:ok, %{"ok" => true}}) do
    {:ok, result} ->
      send(owner, {:websocket_frame, Jason.encode!(%{id: id, result: result})})

    {:error, error} ->
      send(owner, {:websocket_frame, Jason.encode!(%{id: id, error: error})})
  end
  ```

  Apply `Process.send_after(self(), {:deliver_setup, owner, id, response}, delay)` when `delay > 0`; deliver immediately when the delay is zero. Add a receive branch for `{:deliver_setup, owner, id, response}` that sends the frame and loops. Preserve the existing default success result.

- [ ] **Step 2: Add the direct readiness regression test.**

  Add a private test helper `connect_ws(overrides)` that calls `SurrealDB.connect_ws/1` with this base keyword list merged with `overrides:

  ```elixir
  [
    endpoint: "ws://localhost:8000/rpc",
    namespace: "test",
    database: "app",
    username: "root",
    password: "root",
    websocket_options: [socket_module: FakeSocket, timeout: 50]
  ]
  ```

  Add a test that calls `connect_ws(request_options: [test_pid: self(), auto_setup: true])`, asserts both setup payloads were observed before the call returns, then immediately calls `SurrealDB.query/2`, sends the query response, and asserts the query result. Do not call `wait_for_setup/0` in this test.

  ```elixir
  test "connect_ws returns only after setup and permits an immediate query" do
    assert {:ok, client} = connect_ws(request_options: [test_pid: self(), auto_setup: true])
    assert_receive {:socket_sent, ^client.connection, _signin}
    assert_receive {:socket_sent, ^client.connection, _use}

    task = Task.async(fn -> SurrealDB.query(client, "SELECT 1") end)
    assert_receive {:socket_sent, ^client.connection, payload}
    decoded = Jason.decode!(payload)

    send(client.connection, {:websocket_frame,
      Jason.encode!(%{id: decoded["id"], result: [%{"status" => "OK", "result" => 1}]})})

    assert {:ok, %SurrealDB.QueryResult{}} = Task.await(task)
  end
  ```

- [ ] **Step 3: Add failing direct error and timeout tests.**

  Add tests using the exact setup overrides below. These tests should fail against the current implementation because `connect_ws/1` returns before setup and does not propagate setup errors:

  ```elixir
  setup_responses: %{"signin" => {:error, %{"code" => "ERR_AUTH", "message" => "bad credentials"}}}
  setup_responses: %{"use" => {:error, %{"code" => "ERR_USE", "message" => "unknown namespace"}}}
  ```

  Assert `%Error{type: :rpc_error, code: "ERR_AUTH"}` and `%Error{type: :rpc_error, code: "ERR_USE"}` respectively. Add a no-response test with `auto_setup: false` and `timeout: 30`, asserting `%Error{type: :websocket_timeout}` and measuring from immediately before `connect_ws/1` to immediately after it returns. Use a tolerant upper bound of 200ms so the test checks one budget without depending on exact scheduler timing.

- [ ] **Step 4: Run the focused tests and confirm the new tests fail for the readiness gap.**

  Run: `mix test test/surreal_db/web_socket_test.exs --seed 0`

  Expected: existing tests may pass, but the new direct readiness/error/timeout tests fail because `connect_ws/1` returns before setup and the current connection process does setup in a blocking callback.

- [ ] **Step 5: Commit the test harness and regression cases.**

  ```bash
  git add test/support/fake_socket.ex test/surreal_db/web_socket_test.exs
  git commit -m "test: define deterministic websocket readiness contract"
  ```

### Task 2: Implement explicit setup phases and one overall deadline

**Files:**
- Modify: `lib/surreal_db/web_socket/connection.ex`
- Test: `test/surreal_db/web_socket_test.exs`

**Interfaces:**
- Add `Connection.await_ready(pid(), timeout()) :: :ok | {:error, SurrealDB.Error.t()}` for the internal direct-client boundary. It is not exported through `SurrealDB` as a public consumer API.
- Extend `Connection.State` with `setup_phase`, `setup_deadline`, `setup_request_id`, and `setup_waiter` fields while retaining `setup_complete?` until all existing tests and state consumers are migrated.
- Internal helpers use these contracts: `begin_setup/1` starts a setup attempt; `send_next_setup_request/1` sends `signin`, `authenticate`, or `use`; `handle_setup_response/2` advances or fails setup; `finish_setup/1` marks readiness and replies to the waiter; `fail_setup/2` replies with the original error or schedules reconnect; `remaining_setup_timeout/1` returns a non-negative millisecond budget.

- [ ] **Step 1: Add a failing direct waiter test at the connection boundary.**

  Start `Connection.start_link/2` with `auto_setup: true`, call `Connection.await_ready(pid, 50)`, and assert `:ok`. Add a no-response case that asserts `{:error, %Error{type: :websocket_timeout}}`. These tests establish the internal synchronization boundary before refactoring the state machine.

- [ ] **Step 2: Replace `perform_setup/1` and `await_response/1` with non-blocking setup state.**

  On `{:websocket_connected, socket_pid}`, call `begin_setup/1`, set `setup_deadline` to `System.monotonic_time(:millisecond) + connect_timeout`, and send the first setup request. Store its request ID in `setup_request_id`; do not call `receive` inside a GenServer callback. For anonymous clients, skip authentication and start with `use`.

  In `handle_info({:websocket_frame, payload}, state)`, decode the frame once. If its response ID equals `setup_request_id`, route it to `handle_setup_response/2`; otherwise preserve the existing pending-RPC/live-event routing. A successful auth response sends `use`; a successful `use` response calls `finish_setup/1`. An error response calls `fail_setup/2` with `Response.to_error/1`.

- [ ] **Step 3: Enforce one deadline for all setup phases.**

  Before every setup send, compute `remaining_setup_timeout/1` from the monotonic deadline. If it is zero, fail with `%Error{type: :websocket_timeout, message: "websocket setup timed out"}`. Schedule one `{:setup_timeout, setup_request_id}` message for the current remaining budget and ignore stale timeout messages whose request ID no longer matches.

  Do not alter the default `@default_timeout = 5_000` or ordinary user-RPC timeout handling. A reconnect setup gets a new deadline when `begin_setup/1` starts.

- [ ] **Step 4: Run setup unit tests and the existing WebSocket suite.**

  Run: `mix test test/surreal_db/web_socket_test.exs --seed 0`

  Expected: setup responses advance through auth and `use`; direct waiter tests pass; existing RPC, live-query, malformed-frame, and lifecycle tests remain green except for tests still using the old direct polling helper, which are addressed in Task 3.

- [ ] **Step 5: Commit the setup state machine.**

  ```bash
  git add lib/surreal_db/web_socket/connection.ex test/surreal_db/web_socket_test.exs
  git commit -m "feat: model websocket setup readiness explicitly"
  ```

### Task 3: Make direct WebSocket connection synchronous and clean up failed clients

**Files:**
- Modify: `lib/surreal_db/web_socket.ex`
- Modify: `lib/surreal_db/web_socket/connection.ex`
- Modify: `test/surreal_db/web_socket_test.exs`

**Interfaces:**
- `SurrealDB.WebSocket.connect/2` remains `{:ok, Client.t()} | {:error, Error.t()}`.
- `Connection.await_ready/2` returns the setup error unchanged, including `:rpc_error`, `:websocket_closed`, and `:websocket_timeout` types.
- On any failed direct connection, `SurrealDB.WebSocket.connect/2` calls `Connection.stop/1` before returning unless the process has already exited.

- [ ] **Step 1: Add process-cleanup assertions to direct failure tests.**

  Capture the fake socket owner PID through `{:fake_socket_started, connection_pid, ..., socket_pid}` or monitor the connection process in a direct connection helper. After auth failure, `USE` failure, and timeout, assert the returned error and `refute Process.alive?(connection_pid)` after a bounded `:DOWN` message. Keep the assertion out of the public client result.

- [ ] **Step 2: Wait for readiness in `SurrealDB.WebSocket.connect/2`.**

  After `Connection.start_link/2` returns `{:ok, pid}`, call `Connection.await_ready(pid, timeout)`, where `timeout` is `Keyword.get(options, :timeout, 5_000)`. On `:ok`, return the WebSocket client. On `{:error, %Error{} = error}`, stop the connection and return the error. Catch an exit caused by a process dying before the waiter is served and normalize it to `:websocket_connect_error`, `:websocket_closed`, or `:websocket_timeout` according to the existing error contract.

  Ensure the waiter timeout and setup deadline use the same overall budget; do not give auth and `use` independent 5-second waits.

- [ ] **Step 3: Remove direct-client setup polling from unit tests.**

  Replace `wait_for_setup()` in every direct `SurrealDB.connect_ws/1` test with the new synchronous contract. Tests that intentionally exercise `Connection.start_link/2` directly may continue to use a private test helper that calls `Connection.await_ready/2`, but no test should read `:sys.get_state(pid).setup_complete?` to establish readiness.

- [ ] **Step 4: Run the focused suite and formatting.**

  Run: `mix format --check-formatted && mix test test/surreal_db/web_socket_test.exs --seed 0`

  Expected: exit 0; direct clients are ready on return, failures stop their connection process, and all existing WebSocket behavior remains covered.

- [ ] **Step 5: Commit direct-client synchronization.**

  ```bash
  git add lib/surreal_db/web_socket.ex lib/surreal_db/web_socket/connection.ex test/surreal_db/web_socket_test.exs
  git commit -m "feat: wait for websocket readiness on direct connect"
  ```

### Task 4: Preserve asynchronous supervised-store reconnect behavior

**Files:**
- Modify: `lib/surreal_db/web_socket/connection.ex`
- Modify: `test/surreal_db/web_socket_test.exs`
- Test: `test/surreal_db/store/supervisor_test.exs`

**Interfaces:**
- `Connection.start_link/2` with `reconnect: true` never waits for setup in its caller.
- `SurrealDB.Store.Supervisor.start_link/3` continues to force `reconnect: true` and the Registry name.
- Store calls during setup continue returning `%Error{type: :websocket_connect_error, message: "websocket connection not ready"}`.

- [ ] **Step 1: Add a reconnecting setup-pending regression test.**

  Start a reconnecting connection with `auto_setup: false`, assert `Connection.start_link/2` returns `{:ok, pid}` quickly, and assert an immediate `SurrealDB.rpc/3` returns the existing not-ready error. Capture the two setup request payloads from `{:socket_sent, ^pid, payload}`, decode each request ID, send successful `:websocket_frame` responses for `signin` and `use`, then assert a later RPC is dispatched. This proves reconnecting startup remains asynchronous while setup can still transition to ready.

- [ ] **Step 2: Add reconnect timeout coverage.**

  Add a test-only `TimeoutThenSucceedSocket` wrapper in `test/surreal_db/web_socket_test.exs`. Its first `start_link/4` delegates to `FakeSocket` with `auto_setup: false`; subsequent starts delegate with `auto_setup: true`. Start a reconnecting connection with `timeout: 20` and `reconnect_backoff: 10`, assert the process remains alive, observe a fresh socket attempt after the first setup timeout, and assert `:connected` is emitted only after the successful second setup. Use the existing telemetry attachment pattern to assert the event ordering without relying on delayed stale frames.

- [ ] **Step 3: Verify setup failure handling for stores.**

  Configure a fake auth error for a reconnecting connection and assert no `:connected` event is emitted for the failed attempt. Verify the process follows the existing supervised/reconnect behavior without changing subscription or pending-RPC semantics.

- [ ] **Step 4: Run store and WebSocket regression tests.**

  Run: `mix test test/surreal_db/store/supervisor_test.exs test/surreal_db/web_socket_test.exs --seed 0`

  Expected: exit 0; direct connections wait, reconnecting connections remain asynchronous, and lifecycle telemetry is emitted only after setup.

- [ ] **Step 5: Commit the store compatibility coverage.**

  ```bash
  git add lib/surreal_db/web_socket/connection.ex test/surreal_db/web_socket_test.exs test/surreal_db/store/supervisor_test.exs
  git commit -m "test: preserve asynchronous websocket store reconnects"
  ```

### Task 5: Remove integration polling and document the public contract

**Files:**
- Modify: `test/support/integration_case.ex`
- Modify: `test/integration/web_socket_integration_test.exs`
- Modify: `docs/transports-and-live-queries.md`

**Interfaces:**
- `integration_ws_client/0` returns the result of `SurrealDB.connect_ws/1` after setup; it no longer exposes or calls `await_ws_ready/0`.
- Direct-client documentation says successful `connect_ws/1` has completed authentication and `USE`.
- Store documentation says startup/reconnect is asynchronous and calls can temporarily return not-ready errors.

- [ ] **Step 1: Remove `await_ws_ready/0` from integration support.**

  Delete `await_ws_ready/1`, its recursive polling implementation, and all calls to it. Keep `connect_ws!/1` as the single error-normalizing helper that raises with the returned `%SurrealDB.Error{}` message.

- [ ] **Step 2: Make the integration WebSocket test issue its first RPC immediately.**

  In `test/integration/web_socket_integration_test.exs`, remove any readiness wait between `integration_ws_client()` and the first query/RPC. Add or retain an assertion that the immediate call succeeds, proving the real-server path follows the same contract as the fake-socket suite.

- [ ] **Step 3: Update transport documentation.**

  Add a paragraph after the WebSocket example stating that `connect_ws/1` waits for socket setup, authentication, and namespace/database selection. State that `websocket_options: [timeout: milliseconds]` is the overall startup deadline and list the high-level failure categories: authentication/`USE` error, timeout, or socket closure. Add a separate paragraph explaining asynchronous supervised-store startup/reconnect behavior.

- [ ] **Step 4: Run integration-support checks without requiring Docker.**

  Run: `mix format --check-formatted && mix test test/integration/web_socket_integration_test.exs --exclude integration`

  Expected: the file is excluded cleanly in ordinary unit mode and formatting passes. Do not start Docker in this task.

- [ ] **Step 5: Commit integration and documentation updates.**

  ```bash
  git add test/support/integration_case.ex test/integration/web_socket_integration_test.exs docs/transports-and-live-queries.md
  git commit -m "docs: document deterministic websocket readiness"
  ```

### Task 6: Run the complete verification matrix and review the implementation against the spec

**Files:**
- Test: all modified files from Tasks 1–5

**Interfaces:**
- No new interfaces. This task verifies the public contract and ensures no unrelated roadmap item was implemented.

- [ ] **Step 1: Run formatting and warnings-as-errors compilation.**

  Run: `mix format --check-formatted && mix compile --warnings-as-errors`

  Expected: exit 0 with no formatting changes and no compiler warnings.

- [ ] **Step 2: Run the complete Docker-free unit suite.**

  Run: `mix test`

  Expected: exit 0, all non-integration tests pass, and no test relies on setup polling for a direct client.

- [ ] **Step 3: Run the real-server integration suite.**

  Run: `./scripts/test-integration`

  Expected: exit 0; the WebSocket integration test connects, authenticates, selects namespace/database, and issues its first RPC without a readiness helper. If the script fails, inspect the printed Compose logs before changing code.

- [ ] **Step 4: Inspect the final diff for scope and secrets.**

  Run: `git diff main...HEAD --check && git diff main...HEAD --stat && rg -n "wait_for_setup|await_ws_ready|setup_complete\?" lib test docs`

  Expected: only the planned implementation/tests/docs changed; `wait_for_setup` and `await_ws_ready` do not remain in normal client/integration paths; `setup_complete?` is not used by callers to establish readiness; no credentials are added to telemetry or test output.

- [ ] **Step 5: Record verification results for handoff.**

  Do not create a code commit for this step. Report the exact command results and any environment limitation, such as Docker being unavailable, instead of weakening or skipping the readiness assertions.
