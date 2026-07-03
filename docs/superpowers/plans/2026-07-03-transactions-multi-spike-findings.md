# Spike findings - first-class transactions (2026-07-03)

SurrealDB version: surrealdb-3.1.5

Setup note: `/health` returned an empty successful response. The scratch
namespace/database did not exist, so they were created with direct SurrealQL:
`DEFINE NAMESPACE IF NOT EXISTS tx_spike; USE NS tx_spike; DEFINE DATABASE IF NOT EXISTS tx_spike;`.
The scratch table also had to be defined before cleanup:
`DEFINE TABLE IF NOT EXISTS person SCHEMALESS`.

## Raw output

```text
=== Q1/Q2/Q4: success - RETURN inside txn; BEGIN/COMMIT/LET entries; LET capture shape ===
SUCCESS raw: [
  %{"result" => nil, "status" => "OK", "time" => "0ns", "type" => nil},
  %{"result" => nil, "status" => "OK", "time" => "4.303703ms", "type" => nil},
  %{"result" => nil, "status" => "OK", "time" => "115.298µs", "type" => nil},
  %{
    "result" => %{
      "a" => [%{"id" => "person:spike_a", "name" => "one"}],
      "b" => [%{"id" => "person:spike_b", "name" => "two"}]
    },
    "status" => "OK",
    "time" => "2.077141ms",
    "type" => nil
  },
  %{"result" => nil, "status" => "OK", "time" => "3.603357ms", "type" => nil}
]
=== Q3: failure - duplicate record id forces a rollback ===
FAILURE raw: [
  %{"result" => nil, "status" => "OK", "time" => "0ns", "type" => nil},
  %{
    "details" => %{"kind" => "NotExecuted"},
    "kind" => "Query",
    "result" => "The query was not executed due to a failed transaction",
    "status" => "ERR",
    "time" => "159.569µs",
    "type" => nil
  },
  %{
    "details" => %{
      "details" => %{"id" => "person:spike_dup"},
      "kind" => "Record"
    },
    "kind" => "AlreadyExists",
    "result" => "Database record `person:spike_dup` already exists",
    "status" => "ERR",
    "time" => "482.351µs",
    "type" => nil
  },
  %{
    "details" => %{"kind" => "Cancelled"},
    "kind" => "Query",
    "result" => "The query was not executed due to a cancelled transaction",
    "status" => "ERR",
    "time" => "0ns",
    "type" => nil
  },
  %{
    "details" => %{"kind" => "NotExecuted"},
    "kind" => "Query",
    "result" => "Cannot COMMIT: the transaction was aborted due to a prior error",
    "status" => "ERR",
    "time" => "0ns",
    "type" => nil
  }
]
=== Q3b: did the rollback undo the first CREATE? (expect empty) ===
post-rollback select: [[]]
done
```

## Assumption check (gates Tasks 5-6)

| # | Assumption baked into the plan | Confirmed? (yes/no + evidence line) |
|---|---|---|
| A1 | Success: the RETURN value is the sole (or last) entry in the results array | Yes, with nuance: RETURN is the last non-COMMIT value entry. Evidence: success response entries are BEGIN nil, LET nil, LET nil, RETURN map, COMMIT nil. |
| A2 | BEGIN and COMMIT emit no result entries of their own | No. Evidence: success response has a leading `status: "OK", result: nil` entry for BEGIN and trailing `status: "OK", result: nil` entry for COMMIT. |
| A3 | Failure: one ERR entry per inner statement in statement order, so entry index i maps to step i (LETs first, RETURN last) | No as written. Evidence: failure response includes BEGIN at index 0, then step entries at indexes 1 and 2, RETURN cancellation at index 3, and COMMIT abort at index 4; step index mapping needs a `statement_index - 1` offset. |
| A4 | Non-failing statements carry the generic message "The query was not executed due to a failed transaction"; the actually-failing statement carries the real error | Partially. Evidence: the prior non-failing step uses the planned generic failed-transaction message; the RETURN entry uses "The query was not executed due to a cancelled transaction"; COMMIT uses "Cannot COMMIT: the transaction was aborted due to a prior error"; the actual duplicate create carries the real `AlreadyExists` error. |
| A5 | `LET $x = (CREATE …)` captures an ARRAY of created records | Yes. Evidence: RETURN map has `"a" => [%{"id" => "person:spike_a", "name" => "one"}]` and `"b" => [%{"id" => "person:spike_b", "name" => "two"}]`. |

## Verdict

- [ ] All assumptions confirmed - Tasks 5-6 proceed as written.
- [x] Some assumption failed - STOP; report to the orchestrator; Tasks 5-6 must be revised (spec §5 has the positional fallback) before execution.
