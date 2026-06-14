# Feature 1 Deficiencies for Later Review

This note captures implementation risks and unresolved design details found during
repo alignment review. It is not a blocker list for the first implementation, but
these items should be revisited before treating the migration runner as complete.

## WebSocket Support Is Intentionally Absent

The current WebSocket connection setup sends the SurrealDB `use` RPC only during
connection initialization. There is no public or internal API for safely changing
namespace/database on an already connected WebSocket client.

Feature 1 should reject WebSocket clients with a structured error instead of
mutating `%SurrealDB.Client{}` namespace/database fields and reusing the existing
connection.

Review later:

- Whether migration execution should support WebSocket clients by opening fresh
  scoped connections.
- Whether the SDK needs an explicit reconnect or `use` API before migrations can
  support WebSocket transport.

## No Existing Bang Function Convention

The SDK currently exposes tuple-returning APIs and does not define bang variants.
`%SurrealDB.Error{}` implements `defexception`, so migration bang functions can
raise the returned error struct, but this establishes a new public convention.

Review later:

- Whether bang APIs should be introduced only for migrations or generalized
  across the SDK.
- Whether raised errors should preserve the original `%SurrealDB.Error{}` exactly
  or be wrapped with migration-specific context.

## Registry Error Taxonomy Is Not Defined

The handoff describes structured migration errors, but the repo currently has no
migration-specific error constructors in `SurrealDB.Error`.

Feature 1 can create `%SurrealDB.Error{type: ...}` values directly, consistent
with existing code, but this may scatter ad hoc error types.

Review later:

- Add named constructors such as `migration_error/2`, `checksum_drift/1`, or
  `unsupported_client_for_migrations/1`.
- Decide stable public error `type` atoms for migration failures.
- Document migration error shapes in the README.

## Query Result Normalization Needs Care

`SurrealDB.query/2` returns `%SurrealDB.QueryResult{results: results}`, where
each SurQL statement contributes one result entry. Registry queries that execute
one `SELECT` usually produce a nested shape like `[[row]]`, not `[row]`.

Feature 1 needs private normalization helpers for registry lookups and update
acknowledgements.

Review later:

- Whether `SurrealDB.QueryResult` should expose helper functions for common
  single-statement cases.
- Whether registry code should assert update counts or accept any successful
  `OK` status.

## Variable Handling Is Client-Side Rendering

The current HTTP transport renders `$variables` into query text before dispatch.
This is adequate for the planned registry queries if values are simple and JSON
encodable, but it is not true server-side parameter binding.

Review later:

- Whether SurrealDB HTTP query support should use a protocol path that preserves
  server-side bindings, if available.
- Whether migration code should avoid variables for record IDs or other values
  where rendered syntax can become ambiguous.

## Failed Rerun Concurrency Is Minimal

The handoff requires failed reruns to update the existing row instead of inserting
a duplicate. That handles the unique index constraint, but it is not a full lock
or distributed coordination model.

Feature 1 should reject existing `running` rows, but concurrent runners may still
race between preflight and `INSERT`/`UPDATE`.

Review later:

- Whether registry mutations should use SurrealDB transactions or conditional
  update checks once the SDK has stronger support for them.
- Whether failed insert/update results should be mapped to a clearer concurrent
  migration error.

## Registry Schema Evolution Is Manual

`install_registry/2` installs the registry schema from `priv`, but there is no
versioning or upgrade path for the SDK-owned registry itself.

Review later:

- Whether the registry schema should have its own version marker.
- How future SDK releases should migrate `sdk_migration` without conflicting
  with application migrations.

## Public Return Shape Needs Final Confirmation

The handoff says `run/2` returns `{:ok, results}`, but does not define the exact
result item structure.

Feature 1 should pick a small explicit structure, for example maps containing
`filename`, `checksum`, and `status`, but this needs to become part of the public
contract.

Review later:

- Define stable statuses such as `:applied`, `:skipped`, and `:failed`.
- Decide whether successful results should include raw query results from each
  migration.
- Decide whether partial progress should be returned on failure.
