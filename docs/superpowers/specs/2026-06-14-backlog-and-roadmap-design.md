# Backlog & Roadmap — Design

**Date:** 2026-06-14
**Status:** Approved structure, pending spec review

## Goal

Establish a backlog and roadmap for the SurrealDB Elixir SDK, and execute the
first two roadmap items this session:

1. Dogfood the SDK into a fresh Phoenix project and verify the install/usage docs against a live SurrealDB.
2. Add and test an Igniter installer task.

A third item surfaced during brainstorming (documenting how to install SurrealDB
itself), plus a backlog of two nice-to-have features.

## Deliverable format

`ROADMAP.md` at the repo root is the canonical, living backlog. It is the
artifact a future contributor (or the user, post-dogfood) looks at first.
This design spec captures the decisions; findings from executing R1/R2 fold
back into both `README.md` and `ROADMAP.md`.

## Environment (verified 2026-06-14)

- Elixir 1.20.1 / Erlang OTP 29 — satisfies the `~> 1.19` requirement in `mix.exs`.
- `phx_new 1.8.1` and `igniter_new 0.5.33` archives installed.
- SurrealDB reachable: `GET http://localhost:8000/health` → 200; `surreal` CLI present.
- Git remote: `git@github.com:michaelwa/hgs_surrealdb_sdk.git`.

## Roadmap items

### R1 — Dogfood install + live round-trip (this session)

Scaffold a throwaway Phoenix app under `/tmp` and verify the documented install path.

- **Dep source (both):** First confirm the README's documented `github:` dep
  resolves; then switch to a `path:` dep pointing at this working copy to iterate
  on any fixes found.
- **Known risk:** the README's `{:hgs_surrealdb_sdk, github: "michaelwa/hgs_surrealdb_sdk"}`
  (no `ref:`) resolves to the default branch. The install/usage docs and the
  schema/migration code live on feature branches; `main` (`c0bf861`) may lack
  them. Expected first finding — likely needs a `ref:` in the docs or a merge to main.
- **Steps:** `deps.get` → `compile` (confirm `SurrealDB.*` modules resolve) →
  live `connect → query → create → select → merge → delete` round-trip, plus a
  `SurrealDB.Schema` + `SurrealDB.Repo` round-trip, against `http://localhost:8000`
  (root/root, ns/db `test`; verify reachable first).
- **Output:** every doc gap captured as a concrete fix to `README.md`.

### R2 — Igniter installer (this session)

Add a `mix surreal_db.install` Igniter task so consumers can `mix igniter.install`
the SDK with config scaffolding.

- Scaffold SurrealDB connection config in the host app's `config/config.exs`
  (endpoint, namespace, database, auth).
- Optionally add a supervised connection child (ties into backlog feature F2).
- Test the task against the same throwaway Phoenix app from R1.
- `igniter_new 0.5.33` is already available locally.

### R3 — "Installing SurrealDB" doc (this session)

Separate from SDK installation. Document the three ways to obtain the database
itself, without assuming which the user wants:

- Build from source.
- Direct install (`curl | sh` install script / `surreal` CLI).
- Docker image.

Lives as its own doc (e.g. `docs/installing-surrealdb.md`), linked from README.

## Backlog — nice-to-have features

### F1 — Telemetry instrumentation

Emit `:telemetry` spans around query/RPC execution (start/stop/exception events
with measurements like duration and metadata like query, namespace, database).
Idiomatic for the Elixir ecosystem; enables Phoenix LiveDashboard integration and
structured logging. Low effort, high observability payoff.

### F2 — Supervised connection / config-driven repo

Allow starting a named SurrealDB connection under the host app's supervision tree,
configured from `config.exs` (Ecto.Repo-style), instead of passing a `client`
explicitly to every call. Pairs naturally with the R2 Igniter installer, which
can scaffold both the config and the supervisor child.

### Deferred ideas (not active backlog)

- Migration generator task (`mix surreal_db.gen.migration`) — complements the existing runner.
- LiveView live-query helper — subscribe a LiveView to a `LIVE SELECT` and push updates to assigns.

## Execution order

R1 → fold doc fixes into `README.md` → R2 → R3 doc → write up `ROADMAP.md`
(capturing R1–R3 outcomes and the F1/F2 backlog).
