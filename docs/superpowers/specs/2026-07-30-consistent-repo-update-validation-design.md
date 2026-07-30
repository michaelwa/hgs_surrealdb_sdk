# Consistent Repo Update Validation — Design

**Date:** 2026-07-30  
**Status:** Approved design, pending written-spec review

## Goal

Make schema-backed updates as predictable and safe as schema-backed creates.
`SurrealDB.Repo.create/4` currently validates attributes before dispatch, but
`SurrealDB.Repo.update/5` passes its attributes directly to SurrealDB. This
means update values can bypass the Zoi schema and unknown fields can be sent to
the database.

The SDK will adopt a strict client-side validation contract for typed partial
updates:

- Validate every supplied update field against the schema's Zoi definition.
- Reject unknown top-level fields before any network request.
- Preserve omitted fields and retain the current `UPDATE ... MERGE` behavior.
- Return `SurrealDB.Schema.ValidationError` for client-side validation failures.
- Apply the same policy to `SurrealDB.Multi.update`.
- Leave raw SurrealQL as the explicit escape hatch for database-native or
  schema-bypassing operations.

This is intentionally a stronger application-level contract than a generic
SurrealDB client. The official Go SDK accepts maps or structs for data
operations and separates replacement (`Update`) from partial merge (`Merge`);
it does not provide this Zoi-schema validation boundary. This SDK's typed Repo
surface should use its schema rather than silently relying on database behavior.

## Scope and non-goals

### In scope

- `SurrealDB.Schema` support for validating a partial attribute map.
- `SurrealDB.Repo.Statement.update/3` validation.
- `SurrealDB.Repo.update/5` behavior and documentation.
- `SurrealDB.Multi.update/5` behavior through the shared statement builder.
- Unit tests proving validation and no-dispatch behavior.
- Integration coverage proving valid partial updates preserve omitted fields.
- README and schema/Repo documentation updates.

### Out of scope

- Introspecting SurrealDB table definitions or automatically deriving Zoi
  schemas from `INFO FOR TABLE`.
- Changing `Repo.update` from merge semantics to replacement semantics.
- Adding a new raw-update API if the existing raw `Repo.query/5` and
  `Multi.raw/4` surfaces are sufficient.
- Adding field-level immutability rules. A declared field, including `id` when
  present in a schema, is validated like any other supplied field; the record
  target remains the separate `id` argument to `update`.
- Validating fields omitted from the update payload. Database defaults,
  computed fields, and existing values remain database concerns.

## Design

### 1. Shared partial-validation boundary

Add a public-internal helper under `SurrealDB.Schema` for partial validation,
for example `validate_partial/2`. It will derive validation from the schema
module's existing `__schema__/0` Zoi object rather than duplicating field
definitions in `Repo` or `Multi`.

The derived validation schema will:

1. Preserve each declared field's existing type, coercion, refinements, and
   nested validation behavior.
2. Treat every top-level field as optional for this operation, so a partial
   update does not fail because required fields are omitted.
3. Reject unrecognized top-level keys instead of stripping them.
4. Return the same `SurrealDB.Schema.ValidationError` shape used by full
   schema validation.

The helper must not mutate or replace the schema module's normal full
validation behavior. `validate/1` remains the contract for complete records
and creates; `validate_partial/2` is specifically for update payloads.

The validated/coerced map returned by the helper becomes the `$attrs` value
sent to SurrealDB. This keeps update behavior consistent with create behavior:
the database receives the schema-approved representation, not the original
unvalidated input.

### 2. Repo update flow

`SurrealDB.Repo.Statement.update/3` remains the single statement-building
boundary for both `Repo` and `Multi`. Its flow becomes:

1. Validate the record identifier with `SurrealDB.Identifier`.
2. Validate the supplied attributes with `schema.validate_partial/2`.
3. Build the existing parameterized statement:

   ```text
   UPDATE <validated-record-id> MERGE $attrs
   ```

4. Return the validated attributes in the variables map.

Validation must short-circuit before `SurrealDB.query/3` is called. An invalid
value, unknown field, or invalid record identifier therefore produces a local
error without network dispatch.

The public return contract remains:

```elixir
{:ok, struct() | nil}
{:error, %SurrealDB.Schema.ValidationError{}}
{:error, %SurrealDB.Error{}}
```

An empty map is a valid partial payload under this design. It retains existing
`MERGE` behavior and is not given a new special-case error unless the
implementation discovers that the server cannot accept it consistently.

### 3. Multi parity

`SurrealDB.Multi` will continue to delegate typed update construction to
`SurrealDB.Repo.Statement.update/3`. No second validation implementation will
be introduced in `Multi`.

When a multi contains an invalid update:

- `Multi.to_query/1` returns `{:error, step_name, reason}`.
- The reason is the same `ValidationError` that direct `Repo.update` would
  return.
- No transaction query is assembled as a dispatchable successful result.
- No network request is made by the multi runner.
- Earlier valid steps are not sent independently; the transaction remains
  all-or-nothing from the caller's perspective.

The first invalid step continues to determine the returned step name, matching
the existing multi validation contract.

### 4. Raw-operation escape hatch

Typed `Repo.update` and `Multi.update` are intentionally strict. Callers that
need to update fields not represented by a Zoi schema, use database-side
expressions, or operate on a deliberately flexible record must use the raw
surfaces:

- `SurrealDB.Repo.query/5` for a custom update query and hydrated results.
- `SurrealDB.Multi.raw/4` for a custom update inside a transaction.

Documentation will show that these paths bypass the typed update validation
boundary. They do not bypass SurrealDB's own permissions, field definitions,
assertions, or schema mode rules.

## Error behavior

Unknown fields are validation failures, not silently stripped attributes and
not database errors. The validation error should identify the offending field
through the existing Zoi-to-`ValidationError` conversion.

Invalid supplied values use the existing Zoi error path and message conversion.
Omitted required fields do not produce errors because partial validation makes
all declared top-level fields optional for this operation.

The implementation should preserve the existing distinction between:

- `ValidationError` for local schema/attribute failures.
- `SurrealDB.Error` for identifier, transport, authentication, query, and
  server-side failures.

## Testing strategy

### Schema tests

Add tests for the partial-validation helper covering:

- A valid subset of fields succeeds.
- A supplied field is type-checked and coerced using its declared Zoi schema.
- An omitted required field is accepted.
- An unknown field returns `ValidationError`.
- Nested schema validation remains active for supplied nested values.
- The existing full `validate/1` behavior is unchanged.

### Statement tests

Update `test/surreal_db/repo/statement_test.exs` to prove:

- `Statement.update/3` returns validated attributes.
- Invalid values return `ValidationError`.
- Unknown fields return `ValidationError`.
- Invalid identifiers retain the existing `SurrealDB.Error` behavior.
- Validation errors do not produce a statement or variables payload.

### Repo tests

Update `test/surreal_db/repo_test.exs` with an adapter that raises if called,
then assert that invalid values and unknown fields return
`ValidationError` without touching the network. Keep the existing valid update
test and assert that the request remains a parameterized `MERGE`.

### Multi tests

Update `test/surreal_db/multi_test.exs` to prove:

- A valid partial update is assembled with the same validated attributes as a
  direct statement.
- An invalid value returns `{:error, step_name, %ValidationError{}}`.
- An unknown field returns the same error shape and step name.
- Invalid update data prevents transaction dispatch.

### Integration tests

Add or extend Repo integration coverage with a schemafull table whose declared
fields match the test schema. Create a record with multiple fields, update only
one field, and assert that the omitted field remains unchanged. Also verify
that an invalid typed update fails locally and that an unknown field cannot be
written through `Repo.update`.

The integration test should not depend on database introspection to establish
the client contract. The database setup exists to verify the end-to-end merge
result and the interaction with schemafull enforcement.

## Documentation changes

Update `README.md` and `docs/schema-and-repo.md` to state that:

- `Repo.create` and `Repo.update` validate typed attributes before dispatch.
- Updates are partial merges; omitted fields are preserved.
- Unknown update fields and invalid supplied values return
  `SurrealDB.Schema.ValidationError`.
- Raw `Repo.query` and `Multi.raw` are the escape hatch for operations outside
  the declared Zoi schema.
- Database `SCHEMAFULL` rules remain active independently of client-side Zoi
  validation.

The docs should avoid claiming that the Zoi schema is a complete mirror of the
database schema. Database-generated, computed, and defaulted fields may be
omitted from an update payload and are handled by SurrealDB.

## Acceptance criteria

- Invalid update values return `SurrealDB.Schema.ValidationError` without a
  network request.
- Unknown update fields return `SurrealDB.Schema.ValidationError` without a
  network request.
- Valid updates may supply only a subset of declared fields.
- Omitted fields remain unchanged under `UPDATE ... MERGE`.
- The validated/coerced attribute map, rather than the original input, is sent
  as `$attrs`.
- `Multi.update` has the same validation policy and error type as
  `Repo.update`.
- Raw update paths are documented as explicit validation escape hatches.
- README and schema/Repo documentation accurately describe the behavior.
- Unit and integration tests cover the direct Repo, statement, and Multi
  paths.

## References

- [SurrealDB Go SDK data operations](https://surrealdb.com/docs/languages/golang/api/core/db)
- [SurrealDB schemafull tables](https://surrealdb.com/docs/learn/schema-management/tables-and-fields/tables)
- [SurrealDB fields and flexible objects](https://surrealdb.com/docs/learn/schema-management/tables-and-fields/fields-and-validation)
