# First-Class Transactions: `Store.transaction/1` + `SurrealDB.Multi`

**Date:** 2026-07-03
**Status:** Approved (design), pending implementation
**Roadmap item:** ROADMAP.md — "First-class transactions"

## 1. Problem

The SDK has no dedicated transaction API. Callers must hand-write a raw
`BEGIN TRANSACTION; …; COMMIT TRANSACTION;` block and send it through
`query/2,3`. The typed `Repo`/`Store` CRUD helpers cannot be composed into one
atomic unit — each is its own query, and a raw block bypasses Zoi validation.

Atomicity is already server-side: SurrealDB executes the whole block
atomically and returns `status: "ERR"` per statement on failure, which
`SurrealDB.query/3` (`ensure_query_success/1`) already maps to an error tuple.
This feature is an **ergonomics + validation layer** over the existing
multi-statement `query` path — no new transport or protocol work.

## 2. Public API

```elixir
multi =
  SurrealDB.Multi.new()
  |> SurrealDB.Multi.create(:user, MyApp.User, %{name: "Jane", email: "j@x.com"})
  |> SurrealDB.Multi.update(:acct, MyApp.Account, "account:abc", %{balance: 100})
  |> SurrealDB.Multi.delete(:old, MyApp.LogEntry, "log:stale")
  |> SurrealDB.Multi.let(:owner, "SELECT * FROM $user.id", %{})
  |> SurrealDB.Multi.raw(:rel, "RELATE $owner->owns->$acct", %{})

MyApp.SurrealStore.transaction(multi)
#=> {:ok, %{user: %MyApp.User{...}, acct: %MyApp.Account{...}, old: %MyApp.LogEntry{...}, owner: ..., rel: ...}}
#=> {:error, step_name, reason}
```

### Operations (v1)

| Builder | Purpose | Validation |
|---|---|---|
| `Multi.create(multi, name, schema, attrs)` | typed CREATE | Zoi via `schema.validate/1` |
| `Multi.update(multi, name, schema, id, attrs)` | typed UPDATE … MERGE | `Identifier.validate/1` on id |
| `Multi.delete(multi, name, schema, id)` | typed DELETE … RETURN BEFORE | `Identifier.validate/1` on id |
| `Multi.let(multi, name, surql, vars \\ %{})` | `LET $name = (<surql>);` binding usable by later steps | name must be a valid identifier |
| `Multi.raw(multi, name, surql, vars \\ %{})` | arbitrary SurrealQL statement inside the block | none (escape hatch) |

Step names are atoms, unique per multi (duplicate name raises `ArgumentError`
at build time, mirroring `Ecto.Multi`), and must be valid SurrealQL
identifiers: every step is LET-bound as `$<step_name>`, so later `let`/`raw`
steps reference earlier results by name (`$user`, `$acct` above). Order of
addition is execution order.

Deliberately **out of v1**: typed read steps (`get`/`all`/`find`),
cross-step Elixir value plumbing (`Multi.run`-style), and an explicit
`Multi.cancel` marker. Client-side validation failure already aborts before
send; a `raw`/`let` step that `THROW`s produces a server-side rollback.

### Runner

- `SurrealDB.transaction(client, multi)` — public function on the `SurrealDB`
  module, parallel to `query/3`.
- `Store.transaction(multi)` — thin delegate added to the `Store.__using__`
  macro: `with {:ok, c} <- client(), do: SurrealDB.transaction(c, multi)`.

### Result contract

- **Success:** `{:ok, %{step_name => hydrated_result}}`. Steps with a schema
  (`create`/`update`/`delete`) hydrate via `schema.hydrate/1`
  (single-record semantics, like `Repo.run_one/4`: `nil` when no record).
  `let`/`raw` steps return their raw result value.
- **Client-side validation failure:** `{:error, step_name, %SurrealDB.Schema.ValidationError{} | %SurrealDB.Error{}}` —
  nothing is sent to the server. This is the "natural abort" path.
- **Server rollback:** `{:error, step_name | :transaction, %SurrealDB.Error{}}` —
  any statement with `status: "ERR"` rolls back the whole block server-side.
  The failing statement is mapped back to its step name when its position is
  identifiable; otherwise the step slot is `:transaction`.

No `changes_so_far` fourth element (unlike `Ecto.Multi`): server-side
atomicity means there are never observable partial changes.

## 3. Architecture

### 3.1 `SurrealDB.Multi` — pure data + assembly (no I/O)

Struct: ordered list of ops `{name, kind, payload}` + name set.

Responsibilities:

1. **Per-step validation** (`validate/1`): Zoi `schema.validate/1` for create;
   `Identifier.validate/1` for update/delete ids and `let` names. Returns
   `:ok` or `{:error, step_name, reason}`. Runs at send time (in
   `SurrealDB.transaction/2`), before assembly.
2. **Fragment building**: each step builds a SurrealQL fragment + native vars
   map, reusing statement builders extracted from `SurrealDB.Repo`
   (see 3.3).
3. **Variable namespacing**: each *typed* step's input vars are renamed
   `s<i>_<key>` (e.g. step 0's `$attrs` → `$s0_attrs`) both in the fragment
   text and the merged vars map, so steps never collide with each other or
   with step-name LET bindings. In `raw`/`let` fragments, only `$<key>`
   occurrences whose key appears in that step's own vars map are rewritten;
   everything else (`$<step_name>` references to earlier steps, SurrealDB
   built-ins) is left untouched. The merged map is passed as the variables
   argument to `query/3`; binding is transport-dependent below that point
   (WebSocket sends native RPC vars; HTTP interpolates via
   `SurrealDB.Variables.apply/2`, which only rewrites `$name`s present in the
   map — so `$<step_name>` LET references survive on both transports).
4. **Block assembly** (`to_query/1`): produces `{surql, vars}` where surql is:

   ```surql
   BEGIN TRANSACTION;
   LET $user = (CREATE type::table($s0___table__) CONTENT $s0_attrs);
   LET $acct = (UPDATE account:abc MERGE $s1_attrs);
   LET $owner = (SELECT * FROM $user.id);
   ...
   RETURN { user: $user, acct: $acct, owner: $owner, ... };
   COMMIT TRANSACTION;
   ```

   Every step is LET-bound as `$<step_name>` and a single terminal
   `RETURN { … }` yields a **name-keyed map** — result mapping is by key,
   never by array position.

### 3.2 `SurrealDB.transaction/2` — the runner

```
validate(multi)                          → {:error, name, reason} (pre-send abort)
Multi.to_query(multi)                    → {surql, vars}
SurrealDB.query(client, surql, vars)     → existing path: RPC, ensure_query_success, QueryResult
map RETURN payload to steps + hydrate    → {:ok, %{name => result}} | {:error, name | :transaction, error}
```

Success mapping: the live spike on SurrealDB 3.1.5 showed that `BEGIN`,
each `LET`, the terminal `RETURN`, and `COMMIT` all emit response entries.
For the assembled block, the terminal RETURN payload is therefore expected at
response index `length(ops) + 1` (index 0 is BEGIN; indexes `1..length(ops)`
are step LET statements; the following index is RETURN; the last index is
COMMIT). The runner maps that RETURN payload by key and hydrates typed steps.

Error mapping on server rollback: `ensure_query_success/1` must surface the
actual failing statement, not the generic transaction cancellation entries,
and include the response statement index in `Error.details.statement_index`.
For the assembled block, a server statement index maps to a step when
`1 <= statement_index <= length(ops)`, with step index `statement_index - 1`.
BEGIN, RETURN, COMMIT, transport/decode failures, and unrecognized response
shapes are attributed to `:transaction`.

### 3.3 Refactor: extract statement builders from `SurrealDB.Repo`

Today `Repo.create/update/delete` couple building + running. Extract the
fragment construction into private-but-shared builders (e.g.
`SurrealDB.Repo.Statement` with `create/2`, `update/2`, `delete/1` returning
`{surql, vars}`), used by both `Repo` (unchanged public behavior) and
`Multi`. Single source of truth for the SurrealQL each typed op emits
(including `DELETE … RETURN BEFORE`, nil-stripping on create content, etc.).

## 4. Error handling summary

| Failure | Where caught | Result |
|---|---|---|
| Invalid attrs (Zoi) | client, pre-send | `{:error, name, %ValidationError{}}` |
| Invalid record id | client, pre-send | `{:error, name, %Error{type: :invalid_identifier}}` |
| Duplicate step name | build time | raises `ArgumentError` |
| Statement fails server-side | server | full rollback; `{:error, name \| :transaction, %Error{}}` |
| Transport/decode failure | existing query path | `{:error, :transaction, %Error{}}` |
| Hydration failure on success payload | client, post-receive | `{:error, name, %ValidationError{}}` (data committed; error signals shape mismatch) |

Note the hydration-failure case: the transaction **has committed**; the error
reports that the returned record didn't match the schema. Documented
explicitly in the moduledoc.

## 5. Spike (implementation step 1 — evidence before commitment)

The §3.1 assembly rests on SurrealDB behaviors to verify against the live
server (via the test_igniter host app / Tidewave `project_eval`) **before**
building on them:

1. `RETURN { … };` inside `BEGIN/COMMIT` — is the returned map the sole
   result entry, or one entry among per-statement entries?
2. Do `BEGIN`, `COMMIT`, and `LET` statements emit entries in the results
   array (and with what status), on the SurrealDB version in use?
3. On a failing statement mid-transaction, what does the response look like —
   per-statement statuses, or a single error? Can the failing statement's
   index be recovered?
4. `LET $x = (CREATE …)` — does `$x` hold the created record(s)? Array or
   object?

**Spike result on SurrealDB 3.1.5:** `RETURN` inside a transaction is usable,
and `LET $x = (CREATE …)` captures an array of created records. `BEGIN` and
`COMMIT` do emit entries, so success mapping must read the RETURN slot at
`length(ops) + 1` rather than `List.last(results)`. On rollback, generic
failed/cancelled entries and the COMMIT-aborted entry can surround the real
error; the failing step is recovered by skipping those generic transaction
messages and then applying the `statement_index - 1` step offset.

**Fallback:** if a future SurrealDB version makes `RETURN`-in-transaction
unusable, switch to positional mapping — send bare statements (no LET-wrap),
filter BEGIN/COMMIT entries from the results array, zip remainder with steps
in order. The Multi API and result contract are unchanged; only `to_query/1`
and result mapping differ. Spike findings get recorded in the plan before
the affected tasks run.

## 6. Testing

- **Unit (no DB):** `SurrealDB.Multi` — assembly output (block text, LET
  wrapping, RETURN map), var namespacing, validation short-circuit with
  correct step attribution, duplicate-name raise, empty-multi behavior
  (`transaction` on an empty multi returns `{:ok, %{}}` without touching the
  server).
- **Runner tests (stubbed transport, like the existing `Repo` tests):**
  `SurrealDB.transaction/2` against `Req` adapter stubs whose response shapes
  are taken from the §5 spike findings — success mapping, server-error step
  attribution, transport failure.
- **Live verification (manual, end of implementation):** a scratch-scope
  script against the running SurrealDB — commit path (all steps visible
  after), rollback path (later step fails → earlier create absent), `let`
  binding consumed by a later `raw` step. The SDK suite itself has no
  live-DB tests; this mirrors how the SDK is verified via the test_igniter
  host app.
- TDD throughout; RED before GREEN per test.

## 7. Documentation

- Moduledoc on `SurrealDB.Multi` with the pipeline example.
- `Store` moduledoc gains a `transaction` line in the API listing.
- README/docs: short "Transactions" section mirroring the moduledoc example.
- ROADMAP.md: move the backlog item to done.
