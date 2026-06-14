# Backlog & Roadmap Execution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify the SDK's install/usage docs by dogfooding into a fresh Phoenix app against a live SurrealDB (R1), add and test an Igniter installer task (R2), document how to install SurrealDB itself (R3), and capture the result plus the F1/F2 feature backlog in a root `ROADMAP.md`.

**Architecture:** R1 is a verification runbook against a throwaway Phoenix app in `/tmp`; findings drive concrete README edits. R2 adds `{:igniter, "~> 0.5"}` as a dep and a `Mix.Tasks.HgsSurrealdbSdk.Install` Igniter task, tested with `Igniter.Test`. R3 is a standalone doc. The final task writes the living `ROADMAP.md`.

**Tech Stack:** Elixir 1.20.1 / OTP 29, Phoenix `phx_new 1.8.1`, Igniter (`igniter_new 0.5.33` archive; `{:igniter, "~> 0.5"}` dep), SurrealDB at `http://localhost:8000`, `req`/`websockex`/`zoi`.

**Conventions for this plan:**
- The SDK working copy is at `/home/michael_intandem/src/elixir_src/prototypes/hgs_surrealdb_sdk` (referred to below as `$SDK`).
- The throwaway app lives at `/tmp/surreal_dogfood`.
- Commits land on the current branch `docs/install-and-usage` unless a step says otherwise.
- Live DB: `http://localhost:8000`, user `root`, pass `root`, namespace `test`, database `test`.

---

## Phase R1 — Dogfood install + live round-trip

This phase is a **verification runbook**. The "expected" outputs are the pass
criteria; any deviation is a *finding* to record in Task R1.7 and fix in the README.

### Task R1.0: Preflight — confirm DB and toolchain

**Files:** none (verification only)

- [ ] **Step 1: Confirm SurrealDB is reachable**

Run: `curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8000/health`
Expected: `200`

- [ ] **Step 2: Confirm a clean scratch location**

Run: `rm -rf /tmp/surreal_dogfood && echo cleared`
Expected: `cleared`

- [ ] **Step 3: Confirm archives present**

Run: `mix archive | grep -iE "phx_new|igniter_new"`
Expected: lines for `phx_new-1.8.1` and `igniter_new-0.5.33`

### Task R1.1: Scaffold the throwaway Phoenix app

**Files:**
- Create: `/tmp/surreal_dogfood/*` (generated)

- [ ] **Step 1: Generate the app (no Ecto — SurrealDB is the datastore, no Postgres needed)**

Run:
```bash
mix phx.new /tmp/surreal_dogfood --app surreal_dogfood --no-ecto --no-mailer --install
```
Expected: project generated, deps fetched, ends with "Start your Phoenix app with ...". If it prompts to install deps, the `--install` flag answers yes.

- [ ] **Step 2: Confirm it compiles clean before adding the SDK**

Run: `cd /tmp/surreal_dogfood && mix compile`
Expected: compiles with no errors (warnings OK).

### Task R1.2: Add the SDK as the documented GitHub dep (validate the documented path)

**Files:**
- Modify: `/tmp/surreal_dogfood/mix.exs`

- [ ] **Step 1: Add the dep exactly as the README documents it**

In `/tmp/surreal_dogfood/mix.exs`, inside `deps/0`, add:
```elixir
{:hgs_surrealdb_sdk, github: "michaelwa/hgs_surrealdb_sdk"}
```

- [ ] **Step 2: Attempt to fetch it**

Run: `cd /tmp/surreal_dogfood && mix deps.get`
Expected (per the spec's known risk): this resolves the **default branch**. If
the default branch lacks the schema/migration/docs code, compilation in the next
task will fail. **Record the actual default-branch behavior as a finding.**

- [ ] **Step 3: Try to compile against the GitHub dep**

Run: `cd /tmp/surreal_dogfood && mix deps.compile hgs_surrealdb_sdk && mix compile`
Expected: either (a) success, or (b) failure because the default branch is behind.
**Record which occurred, and the exact error if it failed**, in Task R1.7.

- [ ] **Step 4: If the GitHub dep is incomplete, record the doc fix needed**

If Step 2/3 showed the default branch is missing code, note the required README
change (add a `ref:` pointing at a branch/tag that has the code, OR the
prerequisite that the work be merged to `main`). Do not edit the README yet —
fixes are batched in Task R1.7.

### Task R1.3: Switch to a path dep to iterate on the live round-trip

**Files:**
- Modify: `/tmp/surreal_dogfood/mix.exs`

- [ ] **Step 1: Replace the github dep with a path dep**

In `/tmp/surreal_dogfood/mix.exs`, change the dep line to:
```elixir
{:hgs_surrealdb_sdk, path: "/home/michael_intandem/src/elixir_src/prototypes/hgs_surrealdb_sdk"}
```

- [ ] **Step 2: Fetch and compile against the working copy**

Run: `cd /tmp/surreal_dogfood && mix deps.get && mix compile`
Expected: compiles. **If the SDK itself emits warnings/errors when consumed as a dep, record them** (e.g. missing optional deps, `bandit`/`tidewave` being dev-only is correct and should NOT leak).

- [ ] **Step 3: Confirm SDK modules resolve**

Run:
```bash
cd /tmp/surreal_dogfood && mix run -e 'IO.inspect(Code.ensure_loaded?(SurrealDB) and function_exported?(SurrealDB, :connect, 1))'
```
Expected: `true`

### Task R1.4: Live core round-trip (connect → query → CRUD)

**Files:**
- Create: `/tmp/surreal_dogfood/dogfood_core.exs`

- [ ] **Step 1: Write a script that exercises the README "Usage" + "CRUD" sections verbatim**

Create `/tmp/surreal_dogfood/dogfood_core.exs`:
```elixir
{:ok, client} =
  SurrealDB.connect(
    endpoint: "http://localhost:8000",
    namespace: "test",
    database: "test",
    username: "root",
    password: "root"
  )

{:ok, _} = SurrealDB.create(client, "person", %{name: "Jane"})
{:ok, people} = SurrealDB.select(client, "person")
IO.inspect(length(people.results), label: "person count >= 1")

{:ok, created} = SurrealDB.create(client, "person:dogfood", %{name: "Dog", active: false})
IO.inspect(created.results, label: "created person:dogfood")

{:ok, _} = SurrealDB.merge(client, "person:dogfood", %{active: true})
{:ok, q} = SurrealDB.query(client, "SELECT * FROM person:dogfood")
IO.inspect(q.results, label: "after merge (active: true)")

{:ok, _} = SurrealDB.delete(client, "person:dogfood")
IO.puts("CORE ROUND-TRIP OK")
```

- [ ] **Step 2: Run it against the live DB**

Run: `cd /tmp/surreal_dogfood && mix run dogfood_core.exs`
Expected: ends with `CORE ROUND-TRIP OK`, no raised errors. **Record any
function-name/arg/return-shape mismatch vs the README as a finding.**

### Task R1.5: Live Schema + Repo round-trip

**Files:**
- Create: `/tmp/surreal_dogfood/dogfood_repo.exs`

- [ ] **Step 1: Write a script using the README "Schema & Repo" section verbatim**

Create `/tmp/surreal_dogfood/dogfood_repo.exs`:
```elixir
defmodule Dogfood.User do
  use SurrealDB.Schema

  table "user"

  schema do
    Zoi.object(%{
      id: Zoi.string() |> Zoi.optional(),
      name: Zoi.string(),
      email: Zoi.string()
    })
  end
end

{:ok, client} =
  SurrealDB.connect(
    endpoint: "http://localhost:8000",
    namespace: "test",
    database: "test",
    username: "root",
    password: "root"
  )

{:ok, %Dogfood.User{} = user} =
  SurrealDB.Repo.create(client, Dogfood.User, %{name: "Jane", email: "jane@example.com"})
IO.inspect(user, label: "created (hydrated struct)")

{:ok, users} = SurrealDB.Repo.all(client, Dogfood.User)
IO.inspect(length(users), label: "user count >= 1")

{:ok, %Dogfood.User{}} = SurrealDB.Repo.find(client, Dogfood.User, %{email: "jane@example.com"})

# validation failure path
case SurrealDB.Repo.create(client, Dogfood.User, %{name: "NoEmail"}) do
  {:error, %SurrealDB.Schema.ValidationError{}} -> IO.puts("validation error path OK")
  other -> IO.inspect(other, label: "UNEXPECTED validation result")
end

IO.puts("REPO ROUND-TRIP OK")
```

- [ ] **Step 2: Run it against the live DB**

Run: `cd /tmp/surreal_dogfood && mix run dogfood_repo.exs`
Expected: prints the hydrated struct, `validation error path OK`, and ends with
`REPO ROUND-TRIP OK`. **Record any deviation from the documented behavior.**

### Task R1.6: Igniter requires igniter dep — verify SDK loads standalone first

**Files:** none (gate before R2 doc edits)

- [ ] **Step 1: Note current consumer experience**

Confirm from R1.3–R1.5 whether a fresh consumer can use the SDK with only the
documented deps. Record in R1.7 whether anything beyond the documented `deps`
entry was needed (e.g. an extra `jason`/`req` declaration the host app needed).

### Task R1.7: Fold all findings into the README

**Files:**
- Modify: `$SDK/README.md`

- [ ] **Step 1: List every finding gathered in R1.1–R1.6**

Write the consolidated finding list (in the working notes / commit body). Each
finding maps to a concrete README edit: dep `ref:` requirement, any
function/signature corrections, any prerequisite steps, any consumer-side dep.

- [ ] **Step 2: Edit the README to match verified reality**

Apply the edits in `$SDK/README.md`. At minimum, if the GitHub default-branch
risk materialized, update the Installation section to pin a working `ref:` (or
state the merge-to-main prerequisite). Correct any usage snippet that did not run
as written.

- [ ] **Step 3: Re-verify a corrected snippet**

Re-run whichever script(s) correspond to edited snippets:
Run: `cd /tmp/surreal_dogfood && mix run dogfood_core.exs && mix run dogfood_repo.exs`
Expected: both end with their `... OK` lines.

- [ ] **Step 4: Commit the README fixes**

```bash
cd $SDK
git add README.md
git commit -m "docs: correct install/usage docs from dogfood findings (R1)"
```
(If R1 found the docs already correct, record that explicitly and skip the commit.)

---

## Phase R2 — Igniter installer

Adds `{:igniter, "~> 0.5"}` as a dependency and a `mix hgs_surrealdb_sdk.install`
task. The task name matches the OTP app so that `mix igniter.install hgs_surrealdb_sdk`
auto-discovers and runs it.

### Task R2.1: Add igniter as a dependency

**Files:**
- Modify: `$SDK/mix.exs:23-30` (the `deps/0` list)

- [ ] **Step 1: Add the igniter dep**

In `$SDK/mix.exs`, add to `deps/0`:
```elixir
{:igniter, "~> 0.5", optional: true}
```
Rationale: `optional: true` keeps igniter out of consumer runtime closures; it is
only needed when running the install task. `Igniter.Test` still works in this
project's own `:test` env because the dep is present in the dep tree.

- [ ] **Step 2: Fetch it**

Run: `cd $SDK && mix deps.get`
Expected: `igniter` and its deps (`sourceror`, `rewrite`, `glob_ex`, ...) resolve.

- [ ] **Step 3: Confirm the project still compiles**

Run: `cd $SDK && mix compile`
Expected: compiles, no new errors.

- [ ] **Step 4: Commit the dep addition**

```bash
cd $SDK && git add mix.exs mix.lock && git commit -m "build: add igniter as optional dep for installer task (R2)"
```

### Task R2.2: Write the failing installer test

**Files:**
- Create: `$SDK/test/mix/tasks/hgs_surrealdb_sdk_install_test.exs`

- [ ] **Step 1: Write the test using Igniter.Test**

Create `$SDK/test/mix/tasks/hgs_surrealdb_sdk_install_test.exs`:
```elixir
defmodule Mix.Tasks.HgsSurrealdbSdk.InstallTest do
  use ExUnit.Case, async: false
  import Igniter.Test

  test "scaffolds default SurrealDB config under :hgs_surrealdb_sdk" do
    test_project()
    |> Igniter.compose_task("hgs_surrealdb_sdk.install", [])
    |> assert_has_patch("config/config.exs", """
    + |config :hgs_surrealdb_sdk,
    + |  endpoint: "http://localhost:8000",
    + |  namespace: "test",
    + |  database: "test"
    """)
  end

  test "honors provided endpoint/namespace/database options" do
    test_project()
    |> Igniter.compose_task("hgs_surrealdb_sdk.install", [
      "--endpoint",
      "http://db.internal:8000",
      "--namespace",
      "app",
      "--database",
      "app"
    ])
    |> assert_has_patch("config/config.exs", """
    + |  endpoint: "http://db.internal:8000",
    """)
  end
end
```

- [ ] **Step 2: Run it to confirm it fails (task does not exist yet)**

Run: `cd $SDK && mix test test/mix/tasks/hgs_surrealdb_sdk_install_test.exs`
Expected: FAIL — the task `hgs_surrealdb_sdk.install` is not found / module undefined.

### Task R2.3: Implement the installer task

**Files:**
- Create: `$SDK/lib/mix/tasks/hgs_surrealdb_sdk.install.ex`

- [ ] **Step 1: Implement the Igniter task**

Create `$SDK/lib/mix/tasks/hgs_surrealdb_sdk.install.ex`:
```elixir
defmodule Mix.Tasks.HgsSurrealdbSdk.Install do
  @shortdoc "Scaffolds SurrealDB SDK configuration into the host app"
  @moduledoc @shortdoc

  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :hgs_surrealdb_sdk,
      example: "mix hgs_surrealdb_sdk.install --namespace app --database app",
      schema: [endpoint: :string, namespace: :string, database: :string]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    opts = igniter.args.options
    endpoint = opts[:endpoint] || "http://localhost:8000"
    namespace = opts[:namespace] || "test"
    database = opts[:database] || "test"

    igniter
    |> Igniter.Project.Config.configure("config.exs", :hgs_surrealdb_sdk, [:endpoint], endpoint)
    |> Igniter.Project.Config.configure("config.exs", :hgs_surrealdb_sdk, [:namespace], namespace)
    |> Igniter.Project.Config.configure("config.exs", :hgs_surrealdb_sdk, [:database], database)
    |> Igniter.add_notice(
      "SurrealDB config written to config/config.exs. Set credentials via runtime.exs/env before production use."
    )
  end
end
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `cd $SDK && mix test test/mix/tasks/hgs_surrealdb_sdk_install_test.exs`
Expected: PASS (both tests). If the `assert_has_patch` whitespace/format differs
from igniter 0.5.33's emitted diff, adjust the expected patch string to match the
actual output shown in the failure message, then re-run. (The config *keys/values*
asserted must not change — only formatting of the expected diff.)

- [ ] **Step 3: Commit the installer**

```bash
cd $SDK && git add lib/mix/tasks/hgs_surrealdb_sdk.install.ex test/mix/tasks/hgs_surrealdb_sdk_install_test.exs
git commit -m "feat: add mix hgs_surrealdb_sdk.install Igniter task (R2)"
```

### Task R2.4: Live test the installer against the throwaway app

**Files:**
- Modify: `/tmp/surreal_dogfood/config/config.exs` (generated by the task)

- [ ] **Step 1: Run the installer in the dogfood app via the path dep**

Run:
```bash
cd /tmp/surreal_dogfood && mix hgs_surrealdb_sdk.install --namespace test --database test --yes
```
Expected: Igniter prints a diff adding `config :hgs_surrealdb_sdk, ...` to
`config/config.exs` and applies it; ends with the install notice.

- [ ] **Step 2: Confirm the config landed and the app still compiles**

Run: `cd /tmp/surreal_dogfood && mix compile`
Expected: compiles clean with the new config present.

- [ ] **Step 3: Record installer findings**

Note any rough edges (task discovery name, missing `--yes` handling, confusing
output) for the README install section and the ROADMAP.

### Task R2.5: Document the Igniter install path in the README

**Files:**
- Modify: `$SDK/README.md` (Installation section)

- [ ] **Step 1: Add an Igniter install subsection**

In `$SDK/README.md` under Installation, add:
```markdown
### Install with Igniter

If your project uses [Igniter](https://hexdocs.pm/igniter), you can add the SDK
and scaffold its config in one step:

\`\`\`bash
mix igniter.install hgs_surrealdb_sdk --namespace app --database app
\`\`\`

This adds the dependency and writes a `config :hgs_surrealdb_sdk, ...` block to
`config/config.exs`. Override `--endpoint`, `--namespace`, and `--database` as needed.
\`\`\`
```
(Adjust the documented dep ref to match whatever R1.7 established.)

- [ ] **Step 2: Commit the README update**

```bash
cd $SDK && git add README.md && git commit -m "docs: document mix igniter.install path (R2)"
```

---

## Phase R3 — "Installing SurrealDB" doc

### Task R3.1: Write the SurrealDB install doc

**Files:**
- Create: `$SDK/docs/installing-surrealdb.md`

- [ ] **Step 1: Write the doc covering all three install methods**

Create `$SDK/docs/installing-surrealdb.md`:
```markdown
# Installing SurrealDB

This SDK talks to a running SurrealDB server; it does not bundle one. Choose
whichever install method fits your environment. All three result in a server you
can reach over HTTP (`http://localhost:8000`) or WebSocket (`ws://localhost:8000/rpc`).

## Option 1: Install script (direct install)

\`\`\`bash
curl -sSf https://install.surrealdb.com | sh
surreal start --user root --pass root memory
\`\`\`

`memory` runs an ephemeral in-memory store; swap for a path (e.g.
`surrealkv://./data`) to persist.

## Option 2: Docker image

\`\`\`bash
docker run --rm --pull always -p 8000:8000 surrealdb/surrealdb:latest \
  start --user root --pass root memory
\`\`\`

## Option 3: Build from source

Requires a Rust toolchain.

\`\`\`bash
git clone https://github.com/surrealdb/surrealdb
cd surrealdb
cargo build --release
./target/release/surreal start --user root --pass root memory
\`\`\`

## Verify it is running

\`\`\`bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8000/health   # expect 200
\`\`\`

Then connect from Elixir per the [README](../README.md#usage).
```

- [ ] **Step 2: Link the doc from the README**

In `$SDK/README.md`, add near the top of Installation:
```markdown
> Need a SurrealDB server first? See [Installing SurrealDB](docs/installing-surrealdb.md).
```

- [ ] **Step 3: Commit the doc**

```bash
cd $SDK && git add docs/installing-surrealdb.md README.md
git commit -m "docs: add SurrealDB server install guide (R3)"
```

---

## Phase: Write the living ROADMAP.md

### Task ROADMAP.1: Create the root ROADMAP.md

**Files:**
- Create: `$SDK/ROADMAP.md`

- [ ] **Step 1: Write ROADMAP.md capturing outcomes + backlog**

Create `$SDK/ROADMAP.md`:
```markdown
# Roadmap

Living backlog for the SurrealDB Elixir SDK. Design rationale lives in
`docs/superpowers/specs/2026-06-14-backlog-and-roadmap-design.md`.

## Done

- **R1 — Dogfood install + live round-trip.** Verified the install/usage docs by
  adding the SDK to a fresh Phoenix app and running a live connect/query/CRUD and
  Schema/Repo round-trip against SurrealDB. Findings folded into the README.
- **R2 — Igniter installer.** `mix igniter.install hgs_surrealdb_sdk` scaffolds
  `config :hgs_surrealdb_sdk, ...` via `Mix.Tasks.HgsSurrealdbSdk.Install`.
- **R3 — Installing SurrealDB guide.** `docs/installing-surrealdb.md` covers the
  install script, Docker image, and build-from-source paths.

## Backlog (nice-to-have)

- **F1 — Telemetry instrumentation.** Emit `:telemetry` start/stop/exception spans
  around query and RPC execution (duration measurement; query/namespace/database
  metadata). Enables LiveDashboard integration and structured logging.
- **F2 — Supervised connection / config-driven repo.** Start a named SurrealDB
  connection under the host app's supervision tree, configured from `config.exs`
  (Ecto.Repo-style), so calls no longer require passing a `client` explicitly.
  Pairs with the R2 installer, which can scaffold the supervisor child.

## Deferred ideas

- Migration generator task (`mix surreal_db.gen.migration`).
- LiveView live-query helper (subscribe a LiveView to a `LIVE SELECT`).

## Publishing

- Not yet on Hex; installed as a git dependency. Hex release is a future milestone
  once F1/F2 land and the public API stabilizes.
```

- [ ] **Step 2: Run the SDK's own test suite as a final gate**

Run: `cd $SDK && mix test`
Expected: all tests pass (including the new installer tests from R2).

- [ ] **Step 3: Commit the roadmap**

```bash
cd $SDK && git add ROADMAP.md && git commit -m "docs: add living ROADMAP with R1-R3 outcomes and F1/F2 backlog"
```

---

## Self-Review notes

- **Spec coverage:** R1 (dogfood + live round-trip) → Phase R1; R2 (Igniter
  installer) → Phase R2; R3 (SurrealDB install doc) → Phase R3; deliverable format
  (`ROADMAP.md`, Approach A) → final phase; F1/F2 backlog → ROADMAP.1. All spec
  sections mapped.
- **Igniter API risk:** `igniter/1` arity, `Igniter.Project.Config.configure/4`,
  and `Igniter.Test`'s `assert_has_patch` diff format are pinned to igniter 0.5.x
  expectations. R2.3 Step 2 explicitly instructs adapting the expected-diff string
  (not the asserted keys/values) to whatever 0.5.33 emits — the failing-test
  feedback loop catches any API drift.
- **GitHub default-branch risk:** R1.2 treats default-branch resolution as the
  expected first finding and routes the fix through R1.7 rather than assuming an
  outcome.
- **Naming consistency:** installer task is `hgs_surrealdb_sdk.install` /
  `Mix.Tasks.HgsSurrealdbSdk.Install` everywhere (matches the OTP app for
  `mix igniter.install` auto-discovery); config app key is `:hgs_surrealdb_sdk`
  throughout.
```
