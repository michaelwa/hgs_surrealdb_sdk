# Real SurrealDB Integration Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide a reproducible, Docker-backed, opt-in ExUnit suite that proves the SDK’s public contracts against SurrealDB `v3.1.5`.

**Architecture:** A pinned Docker Compose service listens only on `127.0.0.1:18000`. A shell runner owns service lifecycle and failure logs; `SurrealDB.IntegrationCase` owns local-endpoint validation, namespace/database setup, unique test-table names, and safe cleanup. Tagged tests run only through `mix test --only integration`, leaving the existing default unit suite Docker-free.

**Tech Stack:** Elixir 1.19, ExUnit, Req, WebSockex, SurrealDB `v3.1.5`, Docker Compose, Bash.

## Global Constraints

- Pin the only supported integration target to `surrealdb/surrealdb:v3.1.5`; never use a `latest` tag.
- `mix test` must exclude `:integration` and must not require Docker.
- All integration tests are `async: false`.
- Default integration endpoints are `http://127.0.0.1:18000` and `ws://127.0.0.1:18000/rpc`.
- Reject non-local endpoints unless `SURREALDB_INTEGRATION_ALLOW_EXTERNAL=1` is set.
- Never remove a namespace or database during test cleanup; remove only uniquely-prefixed test tables.
- Run the implementation in a worktree before modifying runtime code, per the worktree skill.

---

## File structure

| File | Responsibility |
|---|---|
| `docker-compose.integration.yml` | Pinned, localhost-only, health-checked SurrealDB service. |
| `scripts/test-integration` | Starts Compose, exports integration config, runs tagged tests, emits logs, cleans up. |
| `test/support/integration_case.ex` | ExUnit helpers for endpoint validation, clients, table scope, and cleanup. |
| `test/test_helper.exs` | Excludes integration-tagged tests from default runs. |
| `test/integration/*_integration_test.exs` | Real-server contract tests grouped by public API. |
| `.github/workflows/ci.yml` | Unit and integration CI jobs using the same runner. |
| `README.md`, `docs/installing-surrealdb.md`, `docs/troubleshooting.md` | Contributor workflow and failure diagnosis. |

### Task 1: Compose service and lifecycle runner

**Files:**
- Create: `docker-compose.integration.yml`
- Create: `scripts/test-integration`
- Test: `scripts/test-integration` (manual command contract)

**Interfaces:**
- Produces Compose service `surrealdb` at `http://127.0.0.1:18000`.
- Produces executable `./scripts/test-integration`.
- Consumes `KEEP_INTEGRATION_DB=1` to retain the service after a run.

- [ ] **Step 1: Create the pinned Compose service**

```yaml
services:
  surrealdb:
    image: surrealdb/surrealdb:v3.1.5
    command: start --log info --user root --pass root memory
    ports:
      - "127.0.0.1:18000:8000"
    healthcheck:
      test: ["CMD-SHELL", "surreal isready --endpoint http://localhost:8000"]
      interval: 2s
      timeout: 2s
      retries: 30
      start_period: 2s
```

- [ ] **Step 2: Verify that Compose rejects no configuration and the service becomes healthy**

Run: `docker compose -f docker-compose.integration.yml up -d --wait`

Expected: exit 0 and `docker compose -f docker-compose.integration.yml ps` reports `surrealdb` as healthy.

- [ ] **Step 3: Write the lifecycle runner**

Implement `scripts/test-integration` with `#!/usr/bin/env bash` and `set -euo pipefail`. It must use this exact service file and environment contract:

```bash
compose=(docker compose -f docker-compose.integration.yml)
cleanup() {
  local status="$1"
  if [ "$status" -ne 0 ]; then
    "${compose[@]}" logs --no-color surrealdb || true
  fi
  if [ "${KEEP_INTEGRATION_DB:-0}" != "1" ]; then
    "${compose[@]}" down --volumes --remove-orphans || true
  fi
  exit "$status"
}

"${compose[@]}" up -d --wait
set +e
SURREALDB_INTEGRATION_ENDPOINT=http://127.0.0.1:18000 \
SURREALDB_INTEGRATION_WS_ENDPOINT=ws://127.0.0.1:18000/rpc \
SURREALDB_INTEGRATION_USERNAME=root \
SURREALDB_INTEGRATION_PASSWORD=root \
SURREALDB_INTEGRATION_NAMESPACE=hgs_sdk_integration \
SURREALDB_INTEGRATION_DATABASE=hgs_sdk_integration \
mix test --only integration
status=$?
set -e
cleanup "$status"
```

Mark it executable with `chmod +x scripts/test-integration`.

- [ ] **Step 4: Verify clean lifecycle behavior before integration tests exist**

Run: `./scripts/test-integration`

Expected: Compose starts, Mix exits successfully with zero selected integration tests, and `docker compose -f docker-compose.integration.yml ps` shows no service after cleanup.

- [ ] **Step 5: Verify retained-service behavior**

Run: `KEEP_INTEGRATION_DB=1 ./scripts/test-integration`

Expected: command exits 0 and the healthy service remains available on port `18000`; then run `docker compose -f docker-compose.integration.yml down --volumes --remove-orphans`.

- [ ] **Step 6: Commit the infrastructure increment**

```bash
git add docker-compose.integration.yml scripts/test-integration
git commit -m "test: add SurrealDB integration runner"
```

### Task 2: Safe ExUnit integration support and test selection

**Files:**
- Create: `test/support/integration_case.ex`
- Modify: `test/test_helper.exs`
- Create: `test/integration/integration_case_test.exs`

**Interfaces:**
- Produces `SurrealDB.IntegrationCase` with `integration_client/0`, `integration_ws_client/0`, `integration_scope/0`, and `integration_table/1` for tests that `use` it.
- Consumes the six `SURREALDB_INTEGRATION_*` variables exported by Task 1.

- [ ] **Step 1: Write failing support-case tests**

Add tests proving that local defaults are accepted, an external endpoint is rejected without opt-in, and scopes are valid and distinct:

```elixir
@moduletag :integration
use SurrealDB.IntegrationCase, async: false

test "integration scope is a unique SurrealQL identifier" do
  assert integration_scope() =~ ~r/^it_[0-9]+$/
  refute integration_scope() == integration_scope()
end
```

Add a unit-style test for the endpoint parser in the same module or a focused
support test: `https://example.com` must raise an error mentioning
`SURREALDB_INTEGRATION_ALLOW_EXTERNAL=1`.

- [ ] **Step 2: Run the new test to verify it fails**

Run: `mix test test/integration/integration_case_test.exs --only integration`

Expected: FAIL because `SurrealDB.IntegrationCase` does not exist.

- [ ] **Step 3: Add default integration exclusion**

Replace `test/test_helper.exs` with:

```elixir
ExUnit.start()
ExUnit.configure(exclude: [integration: true])
```

- [ ] **Step 4: Implement `SurrealDB.IntegrationCase`**

Implement a `__using__/1` macro that imports the three helper functions and
sets `async: false`. Implement endpoint validation with `URI.parse/1`:

```elixir
defp external_endpoint?(endpoint) do
  uri = URI.parse(endpoint)
  uri.host not in ["127.0.0.1", "localhost"] or uri.port != 18_000
end
```

Raise `ArgumentError` for an external endpoint unless the explicit opt-in is
`"1"`. Build clients with `SurrealDB.connect/1` and `SurrealDB.connect_ws/1`.
Create the configured namespace/database with a privileged HTTP client using
`DEFINE NAMESPACE IF NOT EXISTS` and `DEFINE DATABASE IF NOT EXISTS`; use the
existing identifier-validation rules before interpolating names.

Generate scopes with `System.unique_integer([:positive])`, returning
`"it_#{integer}"`. `integration_table/1` must validate its suffix, return
`"#{integration_scope()}_#{suffix}"`, register that table in the test process,
and cleanup each registered table with:

```surql
REMOVE TABLE IF EXISTS it_123456_users;
```

Use the existing identifier validation before interpolation. Run cleanup through
`on_exit`; never call `REMOVE NAMESPACE` or `REMOVE DATABASE`.

- [ ] **Step 5: Run focused and default test commands**

Run: `./scripts/test-integration && mix test && mix test --only integration`

Expected: the support case passes in the tagged suite; default `mix test`
reports no integration execution and remains green.

- [ ] **Step 6: Commit the safe test foundation**

```bash
git add test/test_helper.exs test/support/integration_case.ex test/integration/integration_case_test.exs
git commit -m "test: add isolated integration test case"
```

### Task 3: HTTP and Repo contract tests

**Files:**
- Create: `test/integration/http_integration_test.exs`
- Create: `test/integration/repo_integration_test.exs`
- Test: both new files

**Interfaces:**
- Consumes `SurrealDB.IntegrationCase` from Task 2.
- Exercises existing `SurrealDB` and `SurrealDB.Repo` public APIs without new production code.

- [ ] **Step 1: Write failing HTTP contract tests**

Cover these exact scenarios in `http_integration_test.exs`:

```elixir
client = integration_client()
assert {:ok, %SurrealDB.QueryResult{results: [[1]]}} = SurrealDB.query(client, "RETURN 1")
assert {:ok, %SurrealDB.QueryResult{results: [[%{"name" => "Jane"}]]}} =
  SurrealDB.query(client, "RETURN { name: $name }", %{name: "Jane"})
assert {:error, %SurrealDB.Error{type: :surreal_error}} = SurrealDB.query(client, "THIS IS INVALID")
```

Define a unique table and prove `SurrealDB.create/3`, `select/2`, `merge/3`,
`patch/3`, and `delete/2` operate against it.

- [ ] **Step 2: Write failing Repo contract tests**

Define an integration-only Zoi schema module with a fixed table name. In
`setup`, remove and define that table. Cover create/get/all/find/update/delete,
hydration into the schema struct, empty-result `{:ok, nil}`, and invalid ID
rejection by using an invalid identifier. The existing unit test remains the
proof that invalid IDs avoid network dispatch.

- [ ] **Step 3: Run the HTTP and Repo tests against Compose**

Run: `./scripts/test-integration`

Expected: FAIL only until the test expectations have been adjusted to the
pinned server’s observed response shape; do not alter SDK behavior merely to
fit an unverified assumption.

- [ ] **Step 4: Implement only harness-side setup/cleanup needed by observed server behavior**

For `table = integration_table("people")`, use
`"DEFINE TABLE #{table} SCHEMALESS;"` in test setup. Cleanup uses only
`"REMOVE TABLE IF EXISTS #{table};"`. Keep all test record IDs and table
names within the integration prefix.

- [ ] **Step 5: Re-run focused and full suites**

Run: `./scripts/test-integration && mix test`

Expected: live HTTP/Repo tests pass; default tests remain independent of Docker.

- [ ] **Step 6: Commit HTTP and Repo coverage**

```bash
git add test/integration/http_integration_test.exs test/integration/repo_integration_test.exs test/support/integration_case.ex
git commit -m "test: cover HTTP and repo contracts against SurrealDB"
```

### Task 4: Transaction and migration contract tests

**Files:**
- Create: `test/integration/transaction_integration_test.exs`
- Create: `test/integration/migrations_integration_test.exs`
- Modify: `test/support/integration_case.ex`

**Interfaces:**
- Consumes live table setup from Task 2 and `SurrealDB.Multi` / `SurrealDB.Migrations` APIs.
- Produces real-server evidence for the transaction response indexing and migration registry assumptions.

- [ ] **Step 1: Write a failing transaction commit/rollback test**

Build a multi with two typed creates and assert both are returned and queryable
after success. Build a second multi where the first create succeeds and a
later `raw` step throws; assert `SurrealDB.transaction/2` returns an error and
the first record is absent after the call.

```elixir
multi =
  SurrealDB.Multi.new()
  |> SurrealDB.Multi.create(:first, User, %{name: "first", email: "first@example.com"})
  |> SurrealDB.Multi.raw(:fail, "THROW 'intentional integration rollback'")

assert {:error, :fail, %SurrealDB.Error{}} = SurrealDB.transaction(client, multi)
assert {:ok, nil} = SurrealDB.Repo.find(client, User, %{email: "first@example.com"})
```

- [ ] **Step 2: Write a failing migration lifecycle test**

Within a directory created by
`Path.join(System.tmp_dir!(), "hgs_surrealdb_sdk_#{System.unique_integer([:positive])}")`,
write one `.surql` migration with required `-- migrate:up` and optional
`-- migrate:down` sections. Register `File.rm_rf/1` in `on_exit`. Test
`install_registry/2`, first `run/2`, skipped rerun, checksum-drift rejection
after changing contents, failed-migration recording, and rollback. Use a
uniquely named migration file and tables.

- [ ] **Step 3: Run the tagged suite and capture the real response shapes**

Run: `./scripts/test-integration`

Expected: failures identify any mismatch between the existing fake response
fixtures and SurrealDB `v3.1.5`; record the observed shape in the test name or
assertion message before changing production code.

- [ ] **Step 4: Add harness cleanup for registry and migration tables**

Extend `IntegrationCase` with `cleanup_migration_row!/2`, which executes only
`DELETE schema_migrations WHERE filename = $filename;` using the unique
migration filename. Remove only the migration-created scoped table through
`integration_table/1`. Do not use `SurrealDB.Migrations.reset/2` as a cleanup
shortcut until its registry-scope semantics are fixed by the separate
migration P1 work.

- [ ] **Step 5: Re-run all integration and unit tests**

Run: `./scripts/test-integration && mix test`

Expected: transaction commit/rollback and migration lifecycle tests pass with
the pinned server; the default suite stays green.

- [ ] **Step 6: Commit transaction and migration coverage**

```bash
git add test/integration/transaction_integration_test.exs test/integration/migrations_integration_test.exs test/support/integration_case.ex
git commit -m "test: cover transaction and migration contracts live"
```

### Task 5: WebSocket, live-query, and disconnect characterization

**Files:**
- Create: `test/integration/web_socket_integration_test.exs`
- Create: `test/integration/live_query_integration_test.exs`
- Create: `test/integration/reconnect_integration_test.exs`
- Modify: `test/support/integration_case.ex`

**Interfaces:**
- Consumes `integration_ws_client/0` from Task 2 and existing `SurrealDB.live/3`, `kill/2`, and telemetry APIs.
- Does not change the asynchronous readiness or subscription-recovery contract; those are separate P0 implementation work.

- [ ] **Step 1: Write the WebSocket contract tests**

Verify a real connection can perform signin, `use`, RPC query, public query,
and RPC error mapping. Until the readiness P0 is implemented, wait for the
documented connected telemetry event in the test before sending the first
query; assert the event’s namespace/database match integration configuration.

- [ ] **Step 2: Write the live-query lifecycle test**

Create a scoped table, then:

```elixir
assert {:ok, subscription} = SurrealDB.live(ws_client, "LIVE SELECT * FROM #{table}", send_to: self())
assert {:ok, _} = SurrealDB.create(http_client, table, %{name: "event"})
assert_receive {:surrealdb_live, subscription.id, %SurrealDB.Live.Event{action: "CREATE"}}, 5_000
assert :ok = SurrealDB.kill(ws_client, subscription)
```

After kill, create another record and `refute_receive` a message for that
subscription within 300 milliseconds.

- [ ] **Step 3: Write disconnect characterization without recovery assertions**

Attach a telemetry handler and read the test-only connection state with
`:sys.get_state(ws_client.connection)`. Close its `socket_pid` through the
state’s `socket_module.close/1`, then assert that a pending caller receives
one structured `:websocket_closed` error and telemetry emits a disconnected
event. Do not assert automatic live-query re-registration; the next P0 spec
owns that behavior.

- [ ] **Step 4: Run the tagged suite to establish timing bounds**

Run: `./scripts/test-integration`

Expected: WebSocket setup and live event tests pass on the pinned image with
the declared 5-second receive timeout. If timing is flaky, fix test
synchronization by awaiting telemetry or a known write result, never by adding
arbitrary sleeps.

- [ ] **Step 5: Re-run the complete quality gate**

Run: `./scripts/test-integration && mix format --check-formatted && mix compile --warnings-as-errors && mix test`

Expected: all live and unit tests pass; formatting and compilation are clean.

- [ ] **Step 6: Commit WebSocket and live-query coverage**

```bash
git add test/integration/web_socket_integration_test.exs test/integration/live_query_integration_test.exs test/integration/reconnect_integration_test.exs test/support/integration_case.ex
git commit -m "test: cover WebSocket and live query contracts live"
```

### Task 6: CI, documentation, and roadmap completion gate

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `README.md`
- Modify: `docs/installing-surrealdb.md`
- Modify: `docs/troubleshooting.md`
- Modify: `ROADMAP.md`

**Interfaces:**
- CI invokes exactly `./scripts/test-integration` for live validation.
- Documentation exposes the same command and safety behavior as Task 1.

- [ ] **Step 1: Add a CI workflow with separate unit and integration jobs**

The unit job runs:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

The integration job installs Elixir/OTP and Docker Compose, then runs:

```bash
./scripts/test-integration
```

Use `if: failure()` to collect:

```bash
docker compose -f docker-compose.integration.yml logs --no-color surrealdb
```

as a CI artifact or job log.

- [ ] **Step 2: Write the README testing section**

Add a concise section containing:

```bash
./scripts/test-integration
KEEP_INTEGRATION_DB=1 ./scripts/test-integration
```

State the Docker prerequisite, pinned `SurrealDB v3.1.5` target, localhost
port `18000`, default cleanup behavior, and that ordinary `mix test` excludes
integration tests.

- [ ] **Step 3: Update installation and troubleshooting guides**

In `docs/installing-surrealdb.md`, state that the integration Compose service
is isolated from the developer’s server on port `8000`. In
`docs/troubleshooting.md`, add exact remedies:

```bash
docker compose -f docker-compose.integration.yml down --volumes --remove-orphans
lsof -iTCP:18000 -sTCP:LISTEN
docker compose -f docker-compose.integration.yml logs --no-color surrealdb
```

- [ ] **Step 4: Add final evidence to the roadmap item**

Update the P0 integration-harness item only after CI is green. Record the
pinned version, the exact local command, and the date verified; move the item
to the Done section only when every §5 contract test from the approved spec is
live and passing.

- [ ] **Step 5: Run the full release-quality verification**

Run: `./scripts/test-integration && mix format --check-formatted && mix compile --warnings-as-errors && mix test && git diff --check`

Expected: all commands exit 0. Confirm that a clean `mix test` output excludes
the integration-tagged files and that CI uses the same runner.

- [ ] **Step 6: Commit delivery and documentation**

```bash
git add .github/workflows/ci.yml README.md docs/installing-surrealdb.md docs/troubleshooting.md ROADMAP.md
git commit -m "ci: run SurrealDB integration harness"
```

## Plan self-review

| Spec requirement | Plan coverage |
|---|---|
| Pinned server, local lifecycle, failure logs, cleanup | Task 1 |
| Local-only guard, isolated scope, default test exclusion | Task 2 |
| HTTP and Repo contracts | Task 3 |
| Transactions and migrations | Task 4 |
| WebSocket, live query, disconnect characterization | Task 5 |
| CI, documentation, version policy, roadmap completion | Task 6 |

The plan deliberately keeps readiness and live-query recovery implementation
out of scope. Their tests establish current behavior now; their separate P0
work later changes the assertions to enforce the new contracts.
