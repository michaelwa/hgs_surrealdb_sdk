# P1 — SurrealDB Value Encoding Contract

## Status

Approved design.

## Problem

The HTTP transport currently renders query variables by applying a regular
expression over the complete SurrealQL string. This can replace `$name` text
inside quoted strings or comments. Values are also encoded mostly as JSON,
which does not preserve SurrealDB-native types such as record IDs and
datetimes.

## Goals

- Make variable replacement lexical so quoted strings and comments are never
  modified.
- Preserve deterministic encoding for strings, booleans, numbers, `nil`,
  lists, and maps.
- Add explicit native record-ID support.
- Encode Elixir `%DateTime{}` values as native SurrealDB datetimes.
- Return structured errors for unsupported or malformed values.
- Keep one encoding boundary shared by raw queries, Repo, Multi, and
  migrations through `SurrealDB.query/3`.
- Verify behavior against the pinned SurrealDB v3.1.5 integration server.

## Non-goals

- Do not infer record IDs or datetimes from ordinary strings.
- Do not redesign the WebSocket RPC protocol; it already sends structured JSON
  parameters rather than rendering an HTTP `/sql` body.
- Do not support every SurrealDB-native type in this item. Unsupported types
  remain explicit errors.
- Do not introduce a general SurrealQL parser or AST.

## Public API

Add `SurrealDB.RecordID` as an explicit native value:

```elixir
{:ok, record_id} = SurrealDB.RecordID.new("user", "abc")
SurrealDB.RecordID.new!("user", "abc")
```

The struct stores the validated `table` and `id` components. The first
contract supports simple identifier table names and string or integer IDs. A
record ID is rendered as an explicit SurrealQL record literal, for example
`r"user:abc"`; IDs are escaped as part of that literal. A plain string such as
`"user:abc"` remains a string.

Elixir `%DateTime{}` values are accepted directly and rendered as native
SurrealQL datetime literals using UTC RFC 3339 form, for example
`d"2026-08-01T00:00:00Z"`.

SurrealDB documents explicit `r` record-ID literals and `d` datetime literals:

- <https://surrealdb.com/docs/reference/query-language/language-primitives/data-types/strings>
- <https://surrealdb.com/docs/reference/query-language/language-primitives/data-types/datetimes>

## Architecture

`SurrealDB.Variables` remains the single encoding boundary. Its flow is:

1. Normalize variable keys to simple identifiers.
2. Recursively encode each supplied value to SurrealQL.
3. Scan the query character-by-character.
4. Replace matching `$name` tokens only in executable SurrealQL regions.
5. Preserve quoted strings, line comments, and block comments byte-for-byte.
6. Return `{:ok, rendered_query}` or `{:error, %SurrealDB.Error{}}`.

The HTTP transport continues to send rendered SurrealQL to `/sql`. No caller
API changes are required: Repo, Multi, migrations, and raw queries already
converge on `SurrealDB.query/3` and therefore inherit the same boundary.

## Value encoding contract

| Elixir value | SurrealQL representation |
| --- | --- |
| binary | quoted and escaped string |
| boolean | `true` or `false` |
| integer/finite float | numeric literal |
| `nil` | `null` |
| list | recursively encoded array |
| map with string/atom keys | recursively encoded object |
| `%DateTime{}` | `d"…RFC3339…"` |
| `%SurrealDB.RecordID{}` | `r"table:id"` |

Nested lists and maps use the same recursive rules, including native values.
Map keys are restricted to strings or atoms; keys are rendered as escaped
quoted SurrealQL strings so punctuation and spaces cannot change query
structure.

The encoder rejects unsupported structs, tuples, functions, PIDs, references,
invalid map keys, non-finite floats, malformed record IDs, and invalid
datetime values. These failures return `SurrealDB.Error` with
`type: :invalid_variables`; encoding must not raise from `Jason.encode!/1` or
from native-value formatting.

## Query scanner contract

The scanner recognizes and preserves:

- single-quoted strings with escapes;
- double-quoted strings with escapes;
- line comments;
- block comments;
- simple variable identifiers matching
  `[A-Za-z_][A-Za-z0-9_]*`.

Only variable tokens in executable code are eligible for replacement. Missing
variables remain unchanged as they do today. A `$name` appearing inside a
string or comment is never replaced.

## Testing strategy

Add focused unit coverage for:

- `SurrealDB.RecordID.new/2` success, invalid tables, invalid IDs, and
  `new!/2` behavior;
- deterministic scalar encoding;
- nested lists and maps;
- native record IDs and `%DateTime{}` values;
- unsupported values and malformed native values returning structured errors;
- variables inside single-quoted strings, double-quoted strings, line
  comments, and block comments;
- repeated variables and missing variables;
- public HTTP requests receiving the expected rendered body;
- no network dispatch after local encoding failure.

Add pinned-server integration coverage proving that record IDs and datetimes
are interpreted as native SurrealDB values rather than strings. Keep ordinary
unit tests Docker-free and run the integration coverage through the existing
`./scripts/test-integration` harness.

## Files and responsibilities

- `lib/surreal_db/record_id.ex`: public record-ID value and validation.
- `lib/surreal_db/variables.ex`: key normalization, recursive value encoder,
  and lexical scanner.
- `lib/surreal_db/error.ex`: structured encoding-error support if a dedicated
  constructor improves consistency.
- `test/surreal_db/record_id_test.exs`: record-ID API tests.
- `test/surreal_db/variables_test.exs`: encoding and scanner tests.
- Existing HTTP/public API tests: dispatch and rendered-body behavior.
- Existing integration test area: native type round-trips.
- `docs/schema-and-repo.md` or a focused value-encoding guide: user-facing
  contract and examples.
- `ROADMAP.md`: completion evidence after verification.
