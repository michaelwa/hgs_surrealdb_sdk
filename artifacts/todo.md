---
we are in an elixir phoenix application. it is being used for testing the the hgs_surrealdb_sdk igniter instation, and verifying the functionality contained within applications consuming this this dependency.

the local repository is located here: ../../prototypes/hgs_surrealdb_sdk.

goals:
- **First-class transactions (`Store.transaction/1` + a `Multi`-style builder).**
  Today the SDK has no dedicated transaction API: callers must hand-write a raw
  `BEGIN TRANSACTION; …; COMMIT TRANSACTION;` block and send it through `query/2,3`,
  and the typed `Repo`/`Store` CRUD helpers can't be composed into one atomic unit
  (each is its own query, and a raw block bypasses Zoi validation). Add a helper
  that assembles a `BEGIN/COMMIT` block from a sequence of typed operations —
  `Ecto.Multi`-style — running per-step Zoi validation before send, binding shared
  variables, and surfacing the rolled-back result as `{:error, _}` (SurrealDB
  already returns `status: "ERR"` per statement on failure, which `query/2` maps to
  an error tuple). `CANCEL TRANSACTION` for explicit aborts. Atomicity stays
  server-side; the helper is an ergonomics + validation layer over the existing
  multi-statement `query` path.
  
additional process instructions: 
- follow the docs/superpowers plans and specs skill
- when the plan is approved add the plan tasks to the selected kanban board
- write plan tasks for lesser models like sonnent and haiku
- create a pr when the plan is completed  
---

test all "mix surreal.*" commands

seed the database

remove "hgs" 

explore adding dashboards 
  full phoenix liveview or ??
  telemetry
explore making the sdk an mcp

---
### specifications for:
- onboarding
- authentication
- authorization
- roles and permissions
- multi-tenancy

---
sw_ideation -> generate specifications and plans
sw_foundry -> execute plans
sw_ -> pr review, security review, refactor review, simplify review

---
organizations/tenants
projects
applications

feature workflow:
  database:
    - design table structures to hold the data
    - create mermaid ERDs as a specification 
    - design the queries required to support the feature
    - create a table of queries as a specification 

---
