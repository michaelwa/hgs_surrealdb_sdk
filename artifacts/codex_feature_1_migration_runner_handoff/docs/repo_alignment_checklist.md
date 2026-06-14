# Repo Alignment Checklist for Codex

Before implementation, inspect the repo and answer these questions internally. Use the answers as hard constraints.

- What is the OTP app name?
- What file path convention is used under `lib/`?
- What module namespace is public?
- Where should new modules live?
- What public query functions already exist?
- What shape do successful query results have?
- What shape do errors have?
- What fields are present on `%SurrealDB.Client{}`?
- How are namespace/database selected for HTTP requests?
- How are namespace/database selected for WebSocket requests?
- Is there a safe way to change namespace/database for connected WebSocket clients?
- What mocking/test helpers already exist?
- What conventions are used for bang/non-bang functions?
- How are errors raised or returned elsewhere in the SDK?
- What commands must pass before completion?

Do not invent answers. Inspect existing files and tests.
