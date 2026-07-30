# Real SurrealDB Integration Harness

**Date:** 2026-07-30
**Status:** Approved (design), pending implementation
**Roadmap item:** ROADMAP.md — “P0 — Real SurrealDB integration harness”

## 1. Problem

The SDK’s 212-test suite validates most behavior through `Req` adapters and a
fake WebSocket implementation. That is useful for fast unit tests, but it does
not prove that the HTTP requests, RPC setup, WebSocket frames, live queries,
transaction response shapes, or migration SurrealQL work against a real
SurrealDB server.

The project has a local start script and installation documentation, but no
repeatable test harness that isolates database state, pins the server version,
or can be run by a contributor and in CI. The existing
`test/surreal_db/repo/integration_test.exs` is a transport-stub test, not a
live-server test.

This feature establishes a deterministic, opt-in real-server suite. It proves
the public contracts that a dog-food application relies on while preserving
the existing fast default test command.

## 2. Goals and non-goals

### Goals

- Pin one supported SurrealDB Docker image for the SDK’s initial compatibility
  contract: `surrealdb/surrealdb:v3.1.5`.
- Provide one local command that starts the test server, waits until it is
  ready, runs the live suite, and prints server logs on failure.
- Keep `mix test` fast and independent of Docker.
- Mark live tests with `@moduletag :integration` and run them only through
  `mix test --only integration`.
- Create and clean up an isolated namespace/database used only by this suite.
- Validate the SDK’s public HTTP, Repo, transaction, migration, WebSocket,
  live-query, and reconnect paths against the pinned server.
- Make the pinned server version and commands discoverable in the README and
  contributor-facing test documentation.

### Non-goals

- A matrix of SurrealDB versions, storage engines, operating systems, or
  authentication modes.
- Replacing the existing adapter and fake-socket unit suite.
- Testing consumer application schemas or business logic.
- Running Docker automatically from ordinary `mix test`.
- Building a generic testcontainers abstraction.
- Making unimplemented P0 WebSocket readiness or live-query recovery behavior
  pass. The harness must expose those gaps; their fixes belong to their own
  P0 specs.

## 3. User-facing workflow

### Local developer workflow

The repository exposes these commands:

```bash
docker compose -f docker-compose.integration.yml up -d --wait
mix test --only integration
docker compose -f docker-compose.integration.yml logs --no-color surrealdb
docker compose -f docker-compose.integration.yml down --volumes --remove-orphans
```

The documented convenience command is:

```bash
./scripts/test-integration
```

It must:

1. Start the pinned Compose service with `up -d --wait`.
2. Run `mix test --only integration` with explicit integration connection
   environment variables.
3. Capture the command’s exit status.
4. Print `docker compose ... logs --no-color surrealdb` when the test command
   fails.
5. Stop the isolated service and remove its volume unless
   `KEEP_INTEGRATION_DB=1` is set.
6. Exit with the original test status.

The script must never target the repository’s regular local container,
`surrealdb_local`, or an endpoint supplied for normal development.

### CI workflow

CI invokes the same `./scripts/test-integration` command after unit checks.
The job has Docker Compose available and does not use a hosted or shared
SurrealDB endpoint. CI uploads Compose logs when the integration command
fails.

## 4. Runtime design

### 4.1 Compose service

Create `docker-compose.integration.yml` with one service:

```yaml
services:
  surrealdb:
    image: surrealdb/surrealdb:v3.1.5
    command: start --log info --user root --pass root memory
    ports:
      - "127.0.0.1:18000:8000"
    healthcheck:
      test: ["CMD", "/surreal", "isready", "--endpoint", "http://localhost:8000"]
      interval: 2s
      timeout: 2s
      retries: 30
      start_period: 2s
```

The service uses `memory` storage, an ephemeral named project, and port
`18000` so it cannot conflict with the documented developer default on `8000`.

### 4.2 Explicit integration configuration

Integration tests read these variables only in the integration helper:

```text
SURREALDB_INTEGRATION_ENDPOINT=http://127.0.0.1:18000
SURREALDB_INTEGRATION_WS_ENDPOINT=ws://127.0.0.1:18000/rpc
SURREALDB_INTEGRATION_USERNAME=root
SURREALDB_INTEGRATION_PASSWORD=root
SURREALDB_INTEGRATION_NAMESPACE=hgs_sdk_integration
SURREALDB_INTEGRATION_DATABASE=hgs_sdk_integration
```

Default values match the Compose service. Any override is allowed only when
`SURREALDB_INTEGRATION_ALLOW_EXTERNAL=1` is also set; otherwise the helper
rejects endpoints other than `127.0.0.1:18000` and `localhost:18000`. This
prevents accidental destructive migration/reset tests against a developer or
shared database.

### 4.3 Test support API

Create `test/support/integration_case.ex` with a single responsibility:
prepare and clean a real-server test scope.

It provides:

```elixir
use SurrealDB.IntegrationCase, async: false

client = integration_client()
ws_client = integration_ws_client()
scope = integration_scope()
```

`integration_client/0` returns an HTTP `SurrealDB.Client` configured for the
isolated namespace/database. `integration_ws_client/0` creates a WebSocket
client against the same scope. `integration_scope/0` returns a unique,
validated table prefix such as `it_123456` for tests that need table-level
isolation.

Suite setup creates the namespace/database with privileged root credentials.
Each test gets a unique table prefix and removes only tables matching that
prefix during `on_exit`. The helper never executes `REMOVE NAMESPACE`,
`REMOVE DATABASE`, or an unqualified destructive statement.

`async: false` is mandatory for the first version. Live queries, migrations,
and shared namespace/database setup are stateful; deterministic behavior is
more valuable than parallel execution. A later optimization may split
read-only tests into an async-safe group after the isolation model is proven.

### 4.4 Test selection

Live tests live under `test/integration/` and start with:

```elixir
@moduletag :integration
use SurrealDB.IntegrationCase, async: false
```

`test/test_helper.exs` excludes `:integration` by default:

```elixir
ExUnit.configure(exclude: [integration: true])
```

`mix test --only integration` overrides this exclusion as standard ExUnit
behavior. Unit tests must not be tagged `:integration`.

## 5. Required contract coverage

The live suite is organized by public behavior, not internal modules.

| Test module | Required scenarios |
|---|---|
| `http_integration_test.exs` | `SurrealDB.connect/1`, `query/2,3`, multi-statement response handling, structured query error, raw CRUD helpers, and safe variable values. |
| `repo_integration_test.exs` | Runtime-defined table, Zoi schema create/get/all/find/update/delete, hydration, no-result semantics, and invalid identifier rejection before network dispatch. |
| `transaction_integration_test.exs` | Commit persists all steps; an intentional failing step rolls back prior writes; returned step mapping and schema hydration match the public `Multi` contract. |
| `migrations_integration_test.exs` | Install registry, run an up migration, idempotent rerun, checksum drift rejection, failed migration state, and a safe rollback path with a paired down section. |
| `web_socket_integration_test.exs` | Connect, authentication, namespace/database selection, immediate RPC/query after the connection contract is met, RPC error mapping, and socket close behavior. |
| `live_query_integration_test.exs` | Start `LIVE SELECT`, create a record, receive `{:surrealdb_live, subscription_id, event}`, kill the subscription, and verify no subsequent event is delivered. |
| `reconnect_integration_test.exs` | Force close the underlying socket or restart the Compose service and characterize the current documented connection event/error behavior without asserting live-query restoration. The separate reconnect-and-live-query P0 feature extends this test with recovery assertions. |

Each test must use a unique table name obtained from `integration_scope/0`.
Schema modules that need compile-time table names may be defined inside the
test module with one fixed, integration-only table name and cleaned in
`on_exit`; the suite is serial, so this is safe.

## 6. Failure model and diagnostics

The test helper distinguishes setup failures from SDK assertion failures.

| Condition | Result |
|---|---|
| Docker/Compose unavailable | The convenience script fails before Mix starts and explains the required Docker Compose version. |
| Server never becomes healthy | The script prints Compose logs and exits non-zero. |
| Integration endpoint is non-local without explicit opt-in | The test helper raises a clear configuration error before any database command. |
| A test fails | ExUnit reports the assertion; the script then prints server logs. |
| Cleanup fails | The test reports cleanup context but retains the original test failure if one exists. |
| `KEEP_INTEGRATION_DB=1` | The script leaves the container/volume running and prints the endpoint for debugging. |

The helper must not hide server errors behind generic assertions. Assertions
should include the returned `%SurrealDB.Error{}` or query result so protocol
differences are diagnosable from CI logs.

## 7. Version policy

`v3.1.5` is the first pinned, supported integration target because the
existing transaction design records live spike findings against that version.
The exact image tag is declared once in `docker-compose.integration.yml` and
repeated in the README’s supported-version table.

Changing the pinned version requires:

1. Updating the Compose image tag and documentation in one change.
2. Running the full integration suite.
3. Recording any protocol differences in a dated spec or changelog entry.
4. Adding a compatibility job before claiming support for both the old and new
   versions.

The SDK does not claim support for `latest`.

## 8. Documentation changes

- `README.md`: add a “Testing against SurrealDB” section with the quick
  command, Docker prerequisite, pinned version, and `KEEP_INTEGRATION_DB=1`
  debugging option.
- `docs/installing-surrealdb.md`: link to the integration harness and clarify
  that its isolated Compose server is separate from normal local development.
- `docs/troubleshooting.md`: add Docker unavailable, port `18000` occupied,
  and health-check timeout guidance.
- `ROADMAP.md`: retain this item as P0 until the required command and contract
  suite run successfully on a clean checkout and CI.

## 9. Acceptance criteria

The roadmap item is complete only when all of the following are true:

- `mix test` succeeds without Docker and excludes integration tests.
- `./scripts/test-integration` succeeds on a clean checkout with Docker
  Compose available.
- The command starts the pinned `v3.1.5` image, waits for readiness, executes
  `mix test --only integration`, and cleans up by default.
- On a deliberately failing integration test, the command exits non-zero and
  prints SurrealDB logs.
- The suite covers every contract listed in §5 using a real server.
- Test data is isolated from normal development endpoints and cleanup never
  removes a namespace/database.
- README and contributor docs state the exact command and supported version.
- CI runs the same integration command and preserves logs on failure.

## 10. Implementation sequencing

1. Add Compose service, local-only guard, convenience script, and default
   integration-test exclusion.
2. Add the integration support case and a single HTTP smoke test to prove the
   harness.
3. Add HTTP and Repo contract tests.
4. Add transaction and migration tests, including safe cleanup.
5. Add WebSocket and live-query tests.
6. Add the reconnect characterization test; make its final assertion match
   the behavior defined by the separate WebSocket recovery P0 work.
7. Add CI and documentation after the local workflow is proven.

The implementation plan must keep each phase independently runnable and must
not mark the roadmap item complete until the live suite covers every contract
in §5.
