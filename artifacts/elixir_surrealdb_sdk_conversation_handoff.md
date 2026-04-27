# Elixir SurrealDB SDK — Conversation Handoff

## Context

The goal is to create an **Elixir-native SDK for SurrealDB**.

The intended workflow is:

- Use ChatGPT for planning, architecture, specifications, prompts, and phased development strategy.
- Use Codex with GPT-5.5 for implementation.
- Avoid scattered copy/paste by creating a project scaffold and handoff documentation that Codex can read directly from a local repository.

---

## User Goal

> I would like to create an Elixir SurrealDB SDK.
>
> I will be using Codex GPT-5.5 to do the coding. My initial plan is for ChatGPT to do the planning and architecture.
>
> I am not sure if I should be doing this initial work here. It seems like I will be doing a lot of copy and pasting to get this setup and going.

---

## Initial Recommendation

The initial planning and architecture work **should happen in ChatGPT**, while actual coding should happen in **Codex**.

ChatGPT is better suited for:

1. Architecture decisions.
2. Public API design.
3. Phase planning.
4. Codex prompts.
5. Acceptance criteria.
6. Test matrix design.
7. Packaging a starter repo or handoff ZIP.

Codex is better suited for:

1. Creating and editing the Mix project.
2. Writing modules.
3. Running tests.
4. Refactoring against compiler/test feedback.
5. Iterating phase by phase.

The key recommendation is to avoid using Codex from a blank prompt. Instead, provide Codex with a real project folder containing specification files, architecture notes, roadmap, phase prompts, and initial code stubs.

---

## Project Strategy

Do **not** start by trying to build full SDK parity with all official SurrealDB SDKs.

Start with a small, usable Elixir-native SDK over HTTP, then expand incrementally.

The recommended initial path is:

```text
Phase 1: Minimal HTTP SDK
Phase 2: CRUD convenience functions
Phase 3: RPC-style client layer
Phase 4: WebSocket transport
Phase 5: Live queries
```

---

## Recommended Architecture Direction

Avoid Rust NIFs for the first version.

A Rust NIF may be useful someday, but it increases:

- Build complexity.
- Packaging complexity.
- Platform compatibility issues.
- Failure modes.

The first version should be:

```text
Elixir-native API
  -> HTTP transport with Req
  -> JSON encoding/decoding with Jason
  -> structured errors
  -> tests against local SurrealDB
```

Then later evolve toward:

```text
Elixir-native API
  -> RPC abstraction
  -> HTTP RPC transport
  -> WebSocket RPC transport
```

This keeps the SDK simple at first while preserving a path toward fuller SurrealDB SDK parity.

---

## Phase 1 — Minimal HTTP SDK

### Goal

Create a usable SDK for basic SurrealQL query execution over HTTP.

### Example API

```elixir
{:ok, client} =
  SurrealDB.connect(
    endpoint: "http://localhost:8000",
    namespace: "test",
    database: "test",
    username: "root",
    password: "root"
  )

SurrealDB.query(client, "SELECT * FROM person")
```

### Initial Modules

```text
SurrealDB
SurrealDB.Client
SurrealDB.Config
SurrealDB.HTTP
SurrealDB.QueryResult
SurrealDB.Error
```

### Initial Dependencies

```elixir
{:req, "~> 0.5"}
{:jason, "~> 1.4"}
```

### Phase 1 Scope

Implement:

- Configuration parsing and validation.
- Client struct.
- HTTP query execution.
- Authentication support.
- Namespace/database headers.
- JSON encoding/decoding.
- Structured result wrapper.
- Structured error wrapper.
- Unit tests.
- Basic example script.

Do **not** implement yet:

- WebSocket transport.
- Live queries.
- Schema/resource mapping.
- GenServer connection management.
- Connection pooling.
- Migrations.
- CLI tooling.

---

## Phase 2 — CRUD Convenience Functions

After basic query execution works, add convenience functions such as:

```elixir
SurrealDB.select(client, "person")
SurrealDB.create(client, "person", %{name: "Jane"})
SurrealDB.update(client, "person:jane", %{name: "Jane Doe"})
SurrealDB.delete(client, "person:jane")
```

These can compile down to SurrealQL or use official HTTP endpoints, depending on what proves cleaner.

---

## Phase 3 — RPC-Style Client

Add an RPC method layer:

```elixir
SurrealDB.RPC.call(client, "query", ["SELECT * FROM person"])
```

This prepares the SDK for better parity with official SurrealDB SDKs.

---

## Phase 4 — WebSocket Transport

Add persistent WebSocket support.

Potential concerns:

- Request IDs.
- Response correlation.
- Reconnect behavior.
- Supervision strategy.
- Authentication lifecycle.
- RPC request/response handling.

Possible modules:

```text
SurrealDB.WebSocket
SurrealDB.RPC.Request
SurrealDB.RPC.Response
SurrealDB.Connection
```

---

## Phase 5 — Live Queries

Add live query support for Phoenix/LiveView-friendly workflows.

Potential API:

```elixir
SurrealDB.live(client, "person", fn event ->
  IO.inspect(event)
end)
```

This should be treated as a later parity target, not part of the initial SDK.

---

## Recommended Project Folder

Codex should receive a repository, not a long pasted prompt.

Recommended structure:

```text
elixir_surrealdb_sdk/
  README.md
  SPEC.md
  ROADMAP.md
  ARCHITECTURE.md
  CODEX.md
  prompts/
    phase_1.md
    phase_2.md
    phase_3.md
  mix.exs
  lib/
    surreal_db.ex
    surreal_db/client.ex
    surreal_db/config.ex
    surreal_db/http.ex
    surreal_db/error.ex
    surreal_db/query_result.ex
  test/
    test_helper.exs
    surreal_db_test.exs
```

---

## Purpose of Each File

### `README.md`

Public-facing description of the SDK:

- What it does.
- Installation instructions.
- Basic examples.
- Current status.

### `SPEC.md`

Product specification:

- Supported transports.
- Public API.
- Error model.
- Authentication behavior.
- Result shape.
- Non-goals.

### `ARCHITECTURE.md`

Internal architecture:

- Modules.
- Responsibilities.
- Dependency boundaries.
- Future HTTP/RPC/WebSocket evolution.

### `ROADMAP.md`

Phased milestones:

- Phase 1: Minimal HTTP SDK.
- Phase 2: CRUD convenience functions.
- Phase 3: RPC layer.
- Phase 4: WebSocket transport.
- Phase 5: Live queries.

### `CODEX.md`

Persistent instructions for Codex:

- Coding standards.
- What not to implement yet.
- How to run tests.
- How to keep work bounded by phase.

### `prompts/phase_1.md`

The direct task prompt for Codex to implement Phase 1.

---

## Recommended Codex Workflow

### 1. Generate starter project

Use ChatGPT to generate a Codex-ready starter ZIP or repository scaffold.

Then locally:

```bash
unzip elixir_surrealdb_sdk_starter.zip
cd elixir_surrealdb_sdk
```

Optionally initialize Git:

```bash
git init
git add .
git commit -m "Initial SDK specification and scaffold"
```

### 2. Open the project in Codex

From inside the repository:

```bash
codex --model gpt-5.5
```

Then tell Codex:

```text
Read CODEX.md, SPEC.md, ARCHITECTURE.md, ROADMAP.md, and prompts/phase_1.md.

Implement Phase 1 only.

Do not implement WebSocket, live queries, schema mapping, or full SDK parity yet.

Run mix format and mix test before finishing.
```

### 3. Let Codex implement only one phase

For Phase 1, Codex should only build:

```text
HTTP query execution
configuration
basic auth/sign-in behavior
structured errors
query result wrapper
tests
examples
```

### 4. Review the diff

After Codex finishes:

```bash
git diff
mix test
mix format --check-formatted
```

Then commit:

```bash
git add .
git commit -m "Implement Phase 1 HTTP query client"
```

### 5. Repeat phase by phase

Recommended loop:

```text
Plan here -> Package/update repo scaffold -> Codex Phase 1 -> test -> commit
Plan here -> Codex Phase 2 -> test -> commit
Plan here -> Codex Phase 3 -> test -> commit
```

---

## Recommended First Codex Prompt

```text
You are implementing an Elixir SDK for SurrealDB.

Read these files first:
- CODEX.md
- SPEC.md
- ARCHITECTURE.md
- ROADMAP.md
- prompts/phase_1.md

Implement Phase 1 only.

Goals:
- Create a minimal Elixir-native SurrealDB SDK.
- Support HTTP-based SurrealQL query execution.
- Use Req for HTTP.
- Use Jason for JSON.
- Provide a clean public API through SurrealDB.
- Return {:ok, result} and {:error, %SurrealDB.Error{}} tuples.
- Add tests for config validation, HTTP request construction, successful query response parsing, and error response parsing.
- Keep the implementation small and idiomatic.

Do not implement:
- WebSocket transport
- live queries
- schema/resource mapping
- GenServer connection management
- connection pooling
- migrations
- CLI tooling

Before finishing:
- Run mix format.
- Run mix test.
- Summarize changed files and remaining gaps.
```

---

## Key Guidance

Do **not** give Codex the whole dream SDK at once.

Give Codex one bounded phase at a time.

The first milestone should be:

> Can I query SurrealDB from Elixir cleanly, with structured results and good errors?

Once that works, everything else becomes additive.

---

## Recommended Next Deliverable

Create a single Codex-ready starter package containing:

```text
elixir_surrealdb_sdk/
  README.md
  SPEC.md
  ROADMAP.md
  ARCHITECTURE.md
  CODEX.md
  prompts/
    phase_1.md
  mix.exs
  lib/
    surreal_db.ex
    surreal_db/client.ex
    surreal_db/config.ex
    surreal_db/http.ex
    surreal_db/error.ex
    surreal_db/query_result.ex
  test/
    test_helper.exs
    surreal_db_test.exs
  examples/
    basic_query.exs
```

Then hand that folder to Codex and ask it to implement Phase 1 only.

