# Codex Handoff — Phase 1: Minimal HTTP Query Client

## Project

Elixir-native SDK for SurrealDB.

## Phase Goal

Create the smallest useful SDK surface that can connect to SurrealDB over HTTP and execute SurrealQL queries.

This phase should produce a working Mix library with a clean public API, basic configuration, HTTP request execution, response parsing, structured errors, tests, and a small example.

## Scope

Implement:

- `SurrealDB` public API module
- `SurrealDB.Client`
- `SurrealDB.Config`
- `SurrealDB.HTTP`
- `SurrealDB.QueryResult`
- `SurrealDB.Error`
- Basic HTTP query execution using `Req`
- JSON encoding/decoding using `Jason`
- Config validation
- Tuple-based return values:
  - `{:ok, result}`
  - `{:error, %SurrealDB.Error{}}`
- Unit tests
- One runnable example script

## Non-Goals

Do not implement:

- WebSocket transport
- Live queries
- RPC request IDs
- GenServer process ownership
- Connection pooling
- Ecto-style schemas
- Migrations
- CLI tools
- Full official SDK parity

## Suggested Public API

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

Also support query variables if SurrealDB HTTP query execution supports them cleanly:

```elixir
SurrealDB.query(client, "SELECT * FROM person WHERE age > $age", %{age: 30})
```

If variable support is uncertain, stub the function shape but document the current limitation.

## Suggested Files

```text
mix.exs
README.md
lib/surreal_db.ex
lib/surreal_db/client.ex
lib/surreal_db/config.ex
lib/surreal_db/http.ex
lib/surreal_db/query_result.ex
lib/surreal_db/error.ex
test/test_helper.exs
test/surreal_db_test.exs
test/surreal_db/config_test.exs
test/surreal_db/http_test.exs
examples/basic_query.exs
```

## Dependencies

Use:

```elixir
{:req, "~> 0.5"}
{:jason, "~> 1.4"}
```

Avoid heavy dependencies unless there is a compelling reason.

## Data Structures

### `SurrealDB.Client`

Suggested struct:

```elixir
defstruct [
  :endpoint,
  :namespace,
  :database,
  :username,
  :password,
  :token,
  headers: []
]
```

The client should be immutable data, not a process, in this phase.

### `SurrealDB.Error`

Suggested struct:

```elixir
defstruct [
  :type,
  :message,
  :status,
  :code,
  :details
]
```

Use `type` atoms such as:

```elixir
:invalid_config
:http_error
:decode_error
:surreal_error
:unexpected_response
```

### `SurrealDB.QueryResult`

Suggested struct:

```elixir
defstruct [
  :raw,
  results: []
]
```

Keep the wrapper thin. Do not over-model SurrealDB responses yet.

## Behavior Requirements

### Config Validation

Validate required fields:

- `endpoint`
- `namespace`
- `database`

Authentication can support either:

- username/password
- token

For now, allow anonymous only if explicitly configured. Prefer explicitness.

### HTTP Request Behavior

The HTTP layer should:

- Build the correct SurrealDB HTTP endpoint for SQL/query execution.
- Send namespace and database headers.
- Send authentication headers if provided.
- Encode request body as needed.
- Decode JSON response.
- Convert non-2xx HTTP status responses into `%SurrealDB.Error{}`.

### Error Handling

No exceptions should be raised for expected operational failures.

Return:

```elixir
{:error, %SurrealDB.Error{}}
```

for:

- invalid config
- HTTP failures
- JSON decode failures
- SurrealDB error responses
- unexpected response shape

## Testing Expectations

Add tests for:

- valid config creates a client
- missing endpoint returns error
- missing namespace returns error
- missing database returns error
- query delegates to HTTP layer
- successful response parses into `SurrealDB.QueryResult`
- HTTP error becomes `%SurrealDB.Error{}`
- JSON decode failure becomes `%SurrealDB.Error{}`
- public API returns tuples, not raised exceptions

Use mocks or request stubs if practical. If not, isolate request-building logic enough to test without a live SurrealDB server.

## Example

Create:

```text
examples/basic_query.exs
```

Example should show:

```elixir
{:ok, client} =
  SurrealDB.connect(
    endpoint: "http://localhost:8000",
    namespace: "test",
    database: "test",
    username: "root",
    password: "root"
  )

IO.inspect(SurrealDB.query(client, "SELECT * FROM person"))
```

## Definition of Done

Phase 1 is complete when:

- `mix deps.get` succeeds
- `mix compile --warnings-as-errors` succeeds
- `mix format` has been run
- `mix test` passes
- README includes a minimal usage example
- No non-goal features were implemented
- Public API is small and documented
