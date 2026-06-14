# Feature 1 Test Matrix

## Pure unit tests

### Checksum

- Same input returns same checksum.
- Different input returns different checksum.
- Checksum is prefixed with `sha256:`.
- Checksum uses lowercase hex.

### File loader

- Loads only `.surql` files.
- Ignores non-`.surql` files.
- Sorts files lexicographically by filename.
- Returns filename, path, contents, and checksum.
- Returns a structured error for missing path.

## Runner option validation

- Missing `path` returns/raises error.
- Missing `target_ns` returns/raises error.
- Missing `target_db` returns/raises error.
- Missing `sdk_version` returns/raises error or falls back only if repo has a clear version source.

## Registry behavior tests

- No registry row -> marks migration running.
- Applied row with matching checksum -> skip.
- Applied row with different checksum -> checksum drift error.
- Running row -> already running error.
- Failed row -> rejected by default.
- Failed row with `allow_failed_rerun?: true` -> updates existing row back to running.
- Failed rerun path increments `attempt_count`.
- Failed rerun path does not insert a duplicate row.

## Execution behavior tests

- Runner marks migration as running before execution.
- Runner executes migration SQL against target namespace/database.
- Successful execution marks row applied.
- Failed execution marks row failed.
- Failure records `error_message`.
- Success clears `error_message`.
- Duration is recorded.
- `sdk_version` is persisted.

## Namespace/database tests

- Registry operations use `registry_ns` and `registry_db`.
- Target migration execution uses `target_ns` and `target_db`.
- Registry defaults are:
  - `sdk_meta`
  - `migration_registry`
- Custom registry namespace/database options override defaults.

## Transport tests

- HTTP client path is supported.
- Connected WebSocket client returns structured unsupported error unless safe repo support exists.

## Integration tests

Real SurrealDB tests should be tagged:

```elixir
@tag :integration
```

They should not be required for normal `mix test`.
