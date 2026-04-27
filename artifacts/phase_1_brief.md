# Phase 1 Brief

## 1. Objective

Phase 1 should deliver a minimal Elixir-native SurrealDB SDK focused on basic SurrealQL query execution over HTTP. The scope should stay intentionally narrow: HTTP first, no WebSocket transport, and only the core query path needed to establish a usable SDK baseline.

## 2. Settled Decisions From The Handoff

The handoff establishes these defaults for Phase 1:

- Start with HTTP transport.
- Use `Req` for HTTP and `Jason` for JSON.
- Expose a clean public API through `SurrealDB`.
- Return `{:ok, result}` and `{:error, %SurrealDB.Error{}}`.
- Start with these modules: `SurrealDB`, `SurrealDB.Client`, `SurrealDB.Config`, `SurrealDB.HTTP`, `SurrealDB.QueryResult`, `SurrealDB.Error`.
- Include config validation, auth support, namespace/database headers, JSON parsing, structured results/errors, unit tests, and a basic example.
- Treat these as explicit non-goals for Phase 1: WebSocket, live queries, schema mapping, GenServer connection management, pooling, migrations, and CLI tooling.

## 3. Current Repo Facts

The local repo is still at the default Mix scaffold baseline:

- OTP app name in [mix.exs](/home/michael_intandem/src/elixir_src/prototypes/hgs_surrealdb_sdk/mix.exs) is `:hgs_surrealdb_sdk`.
- The current top-level namespace is `HgsSurrealdbSdk` in [lib/hgs_surrealdb_sdk.ex](/home/michael_intandem/src/elixir_src/prototypes/hgs_surrealdb_sdk/lib/hgs_surrealdb_sdk.ex) and [lib/hgs_surrealdb_sdk/application.ex](/home/michael_intandem/src/elixir_src/prototypes/hgs_surrealdb_sdk/lib/hgs_surrealdb_sdk/application.ex).
- `mix.exs` does not yet include `Req` or `Jason`.
- Existing code and tests are placeholder hello-world scaffold only, including [test/hgs_surrealdb_sdk_test.exs](/home/michael_intandem/src/elixir_src/prototypes/hgs_surrealdb_sdk/test/hgs_surrealdb_sdk_test.exs).
- The intended public SDK namespace from the handoff is `SurrealDB`, which does not match the current scaffold naming.

## 4. Open Decisions To Resolve Before Implementation

These choices still affect implementation details and should be resolved or explicitly accepted as defaults:

- Naming strategy: keep the OTP app `:hgs_surrealdb_sdk` and expose `SurrealDB`, or rename the app/module scaffold now.
- Authentication behavior: use HTTP basic auth only, SurrealDB `signin`, or support both in Phase 1.
- Query result shape: wrap the raw SurrealDB response mostly as-is, or normalize it into a smaller `%SurrealDB.QueryResult{}`.
- Test strategy: start with mocked/unit-heavy HTTP coverage only, or include local integration coverage against a running SurrealDB instance in Phase 1.
- Error model: define the minimum fields that must be preserved from HTTP failures and SurrealDB error payloads.

If these are still unanswered, the brief should assume:

- Keep the OTP app/package name as-is for now unless branding or public package naming matters immediately.
- Expose `SurrealDB` as the public API even if the internal app name remains unchanged.
- Start with mocked/unit tests and defer local integration automation if it slows Phase 1.

## 5. Immediate Next Planning Steps

After review, the next work should be:

- Convert this brief into a Phase 1 `SPEC.md` for the repo.
- Add a focused Phase 1 implementation prompt document.
- Resolve the naming, auth, and result-shape questions.
- Then implement only the HTTP query client slice.
