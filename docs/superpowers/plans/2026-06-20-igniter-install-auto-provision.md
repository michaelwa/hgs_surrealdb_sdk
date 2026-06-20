# Igniter Install Auto-Provisioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `mix igniter.install hgs_surrealdb_sdk` automatically create the
configured namespace/database (instead of leaving the user to guess), and make
every `surreal_db.*` task fail loudly instead of silently defaulting to the
wrong `test/test` namespace/database when `--store` is omitted.

**Architecture:** A new `config :app, :surrealdb_stores, [...]` registry
(mirrors Ecto's `ecto_repos`) lets `MigrationTaskHelpers` auto-detect a single
configured store. The installer writes that registry entry and queues
`mix surreal_db.create --store <Module>` via `Igniter.add_task/3`, which
Igniter runs automatically right after the user confirms the generated file
changes — no live network calls or prompts inside the pure `igniter/1`
planning phase.

**Tech Stack:** Elixir, Igniter (Mix task generators), ExUnit.

## Global Constraints

- Do not change the DDL in `create_database!`/`drop_database!` — `DEFINE
  NAMESPACE/DATABASE IF NOT EXISTS` is already idempotent and stays as-is.
- No interactive prompts or network calls inside `Mix.Tasks.HgsSurrealdbSdk.Install.igniter/1` — that callback runs during `--dry-run` previews and directly inside unit tests via `Igniter.compose_task/3`, so it must stay a pure description of file/task changes.
- Explicit `--store <Module>` usage and explicit `--namespace`/`--database` CLI usage (with no store involved) must keep working exactly as today.
- The `:endpoint` default (`http://localhost:8000`) and the `root`/`root` auth default are not touched — only the hardcoded `namespace`/`database` defaults of `"test"` are removed.
- Removing the `test/test` default is an intentional breaking change for any bare `mix surreal_db.create` call that relied on it with zero or multiple stores registered and no manual scope — this is the bug being fixed, not a regression to guard against.

---

### Task 1: Remove the silent `test/test` default in `MigrationTaskHelpers`

**Files:**
- Modify: `lib/mix/tasks/surreal_db/migration_task_helpers.ex:210-218`
- Test: `test/mix/tasks/surreal_db_migration_task_helpers_test.exs`

**Interfaces:**
- Consumes: existing `present?/1` private helper already defined at the bottom of `migration_task_helpers.ex` (`defp present?(value) when is_binary(value), do: String.trim(value) != ""` / `defp present?(value), do: not is_nil(value)`).
- Produces: `client_options/1` now raises `Mix.Error` (via `Mix.raise/1`) instead of silently defaulting `namespace`/`database` to `"test"`. Task 2 will build on this by making `store_options/1` resolve more scope before this guard runs.

- [ ] **Step 1: Add a new failing test, and harden two existing tests that accidentally depend on the default**

In `test/mix/tasks/surreal_db_migration_task_helpers_test.exs`, the two tests below currently pass no `--store`, `--namespace`, or `--database` at all and rely on the implicit `test/test` fallback to make `build_client!/1` succeed. Add explicit scope flags so they keep testing what they actually mean to test (migration path/step parsing, not namespace resolution):

Replace:
```elixir
  test "migration_opts accepts ecto-style migration flags" do
    opts =
      Helpers.parse!([
        "--migrations-path",
        "priv/a",
        "--migrations-path",
        "priv/b",
        "-n",
        "2",
        "--to",
        "20260619000000"
      ])

    client = Helpers.build_client!(opts)
    migration_opts = Helpers.migration_opts(client, opts)

    assert migration_opts[:path] == ["priv/a", "priv/b"]
    assert migration_opts[:step] == 2
    assert migration_opts[:to] == "20260619000000"
  end
```

With:
```elixir
  test "migration_opts accepts ecto-style migration flags" do
    opts =
      Helpers.parse!([
        "--namespace",
        "app_ns",
        "--database",
        "app_db",
        "--migrations-path",
        "priv/a",
        "--migrations-path",
        "priv/b",
        "-n",
        "2",
        "--to",
        "20260619000000"
      ])

    client = Helpers.build_client!(opts)
    migration_opts = Helpers.migration_opts(client, opts)

    assert migration_opts[:path] == ["priv/a", "priv/b"]
    assert migration_opts[:step] == 2
    assert migration_opts[:to] == "20260619000000"
  end
```

Replace:
```elixir
  test "target_opts maps rollback --all to a large step count" do
    opts = Helpers.parse!(["--all"])
    client = Helpers.build_client!(opts)

    assert Helpers.target_opts(client, opts)[:steps] == 9_223_372_036_854_775_807
  end
```

With:
```elixir
  test "target_opts maps rollback --all to a large step count" do
    opts = Helpers.parse!(["--namespace", "app_ns", "--database", "app_db", "--all"])
    client = Helpers.build_client!(opts)

    assert Helpers.target_opts(client, opts)[:steps] == 9_223_372_036_854_775_807
  end
```

Then add a new test right after `"build_client! reads generated store config and allows CLI overrides"`:

```elixir
  test "build_client! raises a clear error when no store or scope is given" do
    opts = Helpers.parse!([])

    assert_raise Mix.Error, ~r/Could not determine a target namespace\/database/, fn ->
      Helpers.build_client!(opts)
    end
  end
```

- [ ] **Step 2: Run the test file and confirm the expected failure**

Run: `mix test test/mix/tasks/surreal_db_migration_task_helpers_test.exs`
Expected: the two hardened tests still PASS (they pass explicit flags, so behavior is unchanged so far). The new `"build_client! raises a clear error..."` test FAILS, because `build_client!/1` currently succeeds with the `test/test` default instead of raising.

- [ ] **Step 3: Remove the default and add the guard**

In `lib/mix/tasks/surreal_db/migration_task_helpers.ex`, replace:
```elixir
  defp client_options(opts) do
    opts
    |> store_options()
    |> Keyword.merge(cli_connection_overrides(opts))
    |> put_default(:endpoint, "http://localhost:8000")
    |> put_default(:namespace, "test")
    |> put_default(:database, "test")
    |> put_default_auth()
  end
```

With:
```elixir
  defp client_options(opts) do
    opts
    |> store_options()
    |> Keyword.merge(cli_connection_overrides(opts))
    |> put_default(:endpoint, "http://localhost:8000")
    |> ensure_scope!()
    |> put_default_auth()
  end

  defp ensure_scope!(opts) do
    if present?(Keyword.get(opts, :namespace)) and present?(Keyword.get(opts, :database)) do
      opts
    else
      Mix.raise("""
      Could not determine a target namespace/database.

      Pass --store <Module>, or --namespace/--database explicitly, or run
      `mix igniter.install hgs_surrealdb_sdk` to generate and register a
      SurrealDB store.
      """)
    end
  end
```

- [ ] **Step 4: Run the test file again and confirm everything passes**

Run: `mix test test/mix/tasks/surreal_db_migration_task_helpers_test.exs`
Expected: PASS (all tests, including the new one).

- [ ] **Step 5: Commit**

```bash
git add lib/mix/tasks/surreal_db/migration_task_helpers.ex test/mix/tasks/surreal_db_migration_task_helpers_test.exs
git commit -m "fix: stop surreal_db.* tasks from silently defaulting to test/test scope"
```

---

### Task 2: Auto-detect a single registered store via `:surrealdb_stores`

**Files:**
- Modify: `lib/mix/tasks/surreal_db/migration_task_helpers.ex:220-234`
- Test: `test/mix/tasks/surreal_db_migration_task_helpers_test.exs`

**Interfaces:**
- Consumes: `ensure_scope!/1` and `present?/1` from Task 1 (unchanged); the test file's existing `ExampleStore` fixture module (`config/0` returning `endpoint/namespace/database/username/password`).
- Produces: `store_options/1` now resolves scope from `Application.get_env(Mix.Project.config()[:app], :surrealdb_stores, [])` when `--store`/`--repo` is omitted. This is what Task 3's installer-written registry entry will be read by later, and it's also exactly what `Mix.raise` messages in Task 1 point users toward.

- [ ] **Step 1: Switch the test module to `async: false` and add a second store fixture**

`Application.get_env/put_env` is global per-VM state; the new tests in this task mutate it, so this file can no longer run `async: true`.

In `test/mix/tasks/surreal_db_migration_task_helpers_test.exs`, replace:
```elixir
defmodule Mix.Tasks.SurrealDb.MigrationTaskHelpersTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.SurrealDb.MigrationTaskHelpers, as: Helpers
  alias SurrealDB.Client

  defmodule ExampleStore do
    def config do
      [
        endpoint: "http://store.example:8000",
        namespace: "store_ns",
        database: "store_db",
        username: "store_user",
        password: "store_pass"
      ]
    end
  end
```

With:
```elixir
defmodule Mix.Tasks.SurrealDb.MigrationTaskHelpersTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.SurrealDb.MigrationTaskHelpers, as: Helpers
  alias SurrealDB.Client

  defmodule ExampleStore do
    def config do
      [
        endpoint: "http://store.example:8000",
        namespace: "store_ns",
        database: "store_db",
        username: "store_user",
        password: "store_pass"
      ]
    end
  end

  defmodule OtherStore do
    def config do
      [
        endpoint: "http://other.example:8000",
        namespace: "other_ns",
        database: "other_db",
        username: "other_user",
        password: "other_pass"
      ]
    end
  end
```

- [ ] **Step 2: Add the failing registry tests**

Add this `describe` block after the `"build_client! raises a clear error..."` test added in Task 1:

```elixir
  describe "store auto-detection via :surrealdb_stores" do
    setup do
      app = Mix.Project.config()[:app]
      previous = Application.get_env(app, :surrealdb_stores)

      on_exit(fn ->
        if previous do
          Application.put_env(app, :surrealdb_stores, previous)
        else
          Application.delete_env(app, :surrealdb_stores)
        end
      end)

      %{app: app}
    end

    test "auto-detects the single registered store when --store is omitted", %{app: app} do
      Application.put_env(app, :surrealdb_stores, [__MODULE__.ExampleStore])

      opts = Helpers.parse!([])
      client = Helpers.build_client!(opts)

      assert client.namespace == "store_ns"
      assert client.database == "store_db"
    end

    test "raises when no store is registered and no scope is given", %{app: app} do
      Application.put_env(app, :surrealdb_stores, [])

      opts = Helpers.parse!([])

      assert_raise Mix.Error, ~r/Could not determine a target namespace\/database/, fn ->
        Helpers.build_client!(opts)
      end
    end

    test "raises on ambiguous multiple stores without --store", %{app: app} do
      Application.put_env(app, :surrealdb_stores, [__MODULE__.ExampleStore, __MODULE__.OtherStore])

      opts = Helpers.parse!([])

      assert_raise Mix.Error, ~r/Multiple SurrealDB stores are registered/, fn ->
        Helpers.build_client!(opts)
      end
    end

    test "explicit --namespace/--database bypasses ambiguous multiple stores", %{app: app} do
      Application.put_env(app, :surrealdb_stores, [__MODULE__.ExampleStore, __MODULE__.OtherStore])

      opts = Helpers.parse!(["--namespace", "manual_ns", "--database", "manual_db"])
      client = Helpers.build_client!(opts)

      assert client.namespace == "manual_ns"
      assert client.database == "manual_db"
    end
  end
```

- [ ] **Step 3: Run the test file and confirm the expected failures**

Run: `mix test test/mix/tasks/surreal_db_migration_task_helpers_test.exs`
Expected: `"auto-detects the single registered store..."` FAILS (registry isn't consulted yet, so no scope is resolved and `ensure_scope!` raises the generic "Could not determine..." error instead of returning a client). `"raises on ambiguous multiple stores..."` FAILS (it raises the generic "Could not determine..." message instead of the expected "Multiple SurrealDB stores are registered..." message, so `assert_raise`'s message match fails). The other two new tests already PASS (they don't depend on registry behavior yet).

- [ ] **Step 4: Implement registry auto-detection**

In `lib/mix/tasks/surreal_db/migration_task_helpers.ex`, replace:
```elixir
  defp store_options(opts) do
    case Keyword.get(opts, :store) || Keyword.get(opts, :repo) do
      nil ->
        []

      store_name ->
        store = module_from_string!(store_name)

        unless Code.ensure_loaded?(store) and function_exported?(store, :config, 0) do
          Mix.raise("#{inspect(store)} is not loaded or does not expose config/0")
        end

        store.config()
    end
  end
```

With:
```elixir
  defp store_options(opts) do
    case Keyword.get(opts, :store) || Keyword.get(opts, :repo) do
      nil ->
        auto_detect_store_options(opts)

      store_name ->
        store_name
        |> module_from_string!()
        |> store_config!()
    end
  end

  defp auto_detect_store_options(opts) do
    case registered_stores() do
      [store] ->
        store_config!(store)

      [] ->
        []

      stores ->
        if manual_scope?(opts) do
          []
        else
          Mix.raise("""
          Multiple SurrealDB stores are registered under :surrealdb_stores \
          (#{Enum.map_join(stores, ", ", &inspect/1)}). Pass --store <Module> to choose one.
          """)
        end
    end
  end

  defp store_config!(store) do
    unless Code.ensure_loaded?(store) and function_exported?(store, :config, 0) do
      Mix.raise("#{inspect(store)} is not loaded or does not expose config/0")
    end

    store.config()
  end

  defp registered_stores do
    Application.get_env(Mix.Project.config()[:app], :surrealdb_stores, [])
  end

  defp manual_scope?(opts) do
    present?(Keyword.get(opts, :namespace)) and present?(Keyword.get(opts, :database))
  end
```

- [ ] **Step 5: Run the test file again and confirm everything passes**

Run: `mix test test/mix/tasks/surreal_db_migration_task_helpers_test.exs`
Expected: PASS (all tests).

- [ ] **Step 6: Commit**

```bash
git add lib/mix/tasks/surreal_db/migration_task_helpers.ex test/mix/tasks/surreal_db_migration_task_helpers_test.exs
git commit -m "feat: auto-detect a single registered SurrealDB store when --store is omitted"
```

---

### Task 3: Installer registers the store, auto-runs provisioning, and explains it

**Files:**
- Modify: `lib/mix/tasks/hgs_surrealdb_sdk.install.ex:33-63`
- Test: `test/mix/tasks/hgs_surrealdb_sdk_install_test.exs`

**Interfaces:**
- Consumes: `Igniter.Project.Config.configure/6` with an `updater:` option and `Igniter.Code.List.prepend_new_to_list/3` (both already used elsewhere in the `igniter` dependency, e.g. `deps/igniter/lib/igniter/project/igniter_config.ex:187-194`); `Igniter.add_task/3` (`deps/igniter/lib/igniter.ex:425-427`).
- Produces: every install now writes `config :app, surrealdb_stores: [App.SurrealStore]` (the registry Task 2 reads) and queues `{"surreal_db.create", ["--store", "App.SurrealStore"]}` in `igniter.tasks`, which Igniter runs automatically after the user confirms the generated changes.

- [ ] **Step 1: Update the two existing config.exs assertions and add two new tests**

In `test/mix/tasks/hgs_surrealdb_sdk_install_test.exs`, replace:
```elixir
  test "writes per-app store config to config/config.exs" do
    test_project()
    |> Igniter.compose_task("hgs_surrealdb_sdk.install", [
      "--namespace",
      "app",
      "--database",
      "app"
    ])
    |> assert_creates("config/config.exs", """
    import Config

    config :test, Test.SurrealStore,
      endpoint: "http://localhost:8000",
      namespace: "app",
      database: "app",
      username: "root",
      password: "root"
    """)
  end
```

With:
```elixir
  test "writes per-app store config to config/config.exs" do
    test_project()
    |> Igniter.compose_task("hgs_surrealdb_sdk.install", [
      "--namespace",
      "app",
      "--database",
      "app"
    ])
    |> assert_creates("config/config.exs", """
    import Config

    config :test, surrealdb_stores: [Test.SurrealStore]

    config :test, Test.SurrealStore,
      endpoint: "http://localhost:8000",
      namespace: "app",
      database: "app",
      username: "root",
      password: "root"
    """)
  end
```

Replace:
```elixir
  test "honors a custom --endpoint" do
    test_project()
    |> Igniter.compose_task("hgs_surrealdb_sdk.install", ["--endpoint", "http://db.internal:8000"])
    |> assert_creates("config/config.exs", """
    import Config

    config :test, Test.SurrealStore,
      endpoint: "http://db.internal:8000",
      namespace: "test",
      database: "test",
      username: "root",
      password: "root"
    """)
  end
```

With:
```elixir
  test "honors a custom --endpoint" do
    test_project()
    |> Igniter.compose_task("hgs_surrealdb_sdk.install", ["--endpoint", "http://db.internal:8000"])
    |> assert_creates("config/config.exs", """
    import Config

    config :test, surrealdb_stores: [Test.SurrealStore]

    config :test, Test.SurrealStore,
      endpoint: "http://db.internal:8000",
      namespace: "test",
      database: "test",
      username: "root",
      password: "root"
    """)
  end
```

Then add two new tests at the end of the module (before the final `end`):

```elixir
  test "queues mix surreal_db.create with the generated store" do
    test_project()
    |> Igniter.compose_task("hgs_surrealdb_sdk.install", [])
    |> assert_has_task("surreal_db.create", ["--store", "Test.SurrealStore"])
  end

  test "notice explains the automatic namespace/database provisioning" do
    test_project()
    |> Igniter.compose_task("hgs_surrealdb_sdk.install", [
      "--namespace",
      "app2",
      "--database",
      "app2"
    ])
    |> assert_has_notice(fn notice ->
      notice =~ "mix surreal_db.create --store Test.SurrealStore" and
        notice =~ ~s("app2/app2" namespace/database)
    end)
  end
```

- [ ] **Step 2: Run the test file and confirm the expected failures**

Run: `mix test test/mix/tasks/hgs_surrealdb_sdk_install_test.exs`
Expected: the two updated config-assertion tests FAIL (the generated file doesn't have the `surrealdb_stores` line yet). The `"queues mix surreal_db.create..."` test FAILS (no task is queued yet). The `"notice explains..."` test FAILS (current notice text doesn't mention `surreal_db.create`).

- [ ] **Step 3: Implement the installer changes**

In `lib/mix/tasks/hgs_surrealdb_sdk.install.ex`, replace the entire `igniter/1` body:
```elixir
    @impl Igniter.Mix.Task
    def igniter(igniter) do
      opts = igniter.args.options
      endpoint = opts[:endpoint] || "http://localhost:8000"
      namespace = opts[:namespace] || "test"
      database = opts[:database] || "test"

      app = Igniter.Project.Application.app_name(igniter)
      store = Module.concat(Igniter.Project.Module.module_name_prefix(igniter), SurrealStore)

      igniter
      |> Igniter.Project.Module.create_module(store, """
      use SurrealDB.Store, otp_app: #{inspect(app)}
      """)
      |> Igniter.Project.Config.configure("config.exs", app, [store, :endpoint], endpoint)
      |> Igniter.Project.Config.configure("config.exs", app, [store, :namespace], namespace)
      |> Igniter.Project.Config.configure("config.exs", app, [store, :database], database)
      |> Igniter.Project.Config.configure("config.exs", app, [store, :username], "root")
      |> Igniter.Project.Config.configure("config.exs", app, [store, :password], "root")
      |> Igniter.Project.Application.add_new_child(store)
      |> Igniter.add_notice("""
      SurrealDB store #{inspect(store)} generated and added to your supervision tree.

      Connection config written to config/config.exs (keyed by #{inspect(app)} /
      #{inspect(store)}). The default credentials are root/root for a local dev
      server. Override them (and the endpoint) per environment in
      config/runtime.exs before deploying, and make sure the target
      namespace/database exist on the server.

      Call it without an explicit client, e.g. `#{inspect(store)}.query("INFO FOR DB")`.
      """)
    end
```

With:
```elixir
    @impl Igniter.Mix.Task
    def igniter(igniter) do
      opts = igniter.args.options
      endpoint = opts[:endpoint] || "http://localhost:8000"
      namespace = opts[:namespace] || "test"
      database = opts[:database] || "test"

      app = Igniter.Project.Application.app_name(igniter)
      store = Module.concat(Igniter.Project.Module.module_name_prefix(igniter), SurrealStore)

      igniter
      |> Igniter.Project.Module.create_module(store, """
      use SurrealDB.Store, otp_app: #{inspect(app)}
      """)
      |> Igniter.Project.Config.configure("config.exs", app, [store, :endpoint], endpoint)
      |> Igniter.Project.Config.configure("config.exs", app, [store, :namespace], namespace)
      |> Igniter.Project.Config.configure("config.exs", app, [store, :database], database)
      |> Igniter.Project.Config.configure("config.exs", app, [store, :username], "root")
      |> Igniter.Project.Config.configure("config.exs", app, [store, :password], "root")
      |> Igniter.Project.Config.configure(
        "config.exs",
        app,
        [:surrealdb_stores],
        [store],
        updater: fn zipper -> Igniter.Code.List.prepend_new_to_list(zipper, store) end
      )
      |> Igniter.Project.Application.add_new_child(store)
      |> Igniter.add_task("surreal_db.create", ["--store", inspect(store)])
      |> Igniter.add_notice("""
      SurrealDB store #{inspect(store)} generated and added to your supervision tree.

      Connection config written to config/config.exs (keyed by #{inspect(app)} /
      #{inspect(store)}). The default credentials are root/root for a local dev
      server. Override them (and the endpoint) per environment in
      config/runtime.exs before deploying.

      Confirming these changes will also run `mix surreal_db.create --store #{inspect(store)}`
      to create the "#{namespace}/#{database}" namespace/database on the target
      server. If the server isn't reachable yet, just run that command yourself
      once it is up.

      Call it without an explicit client, e.g. `#{inspect(store)}.query("INFO FOR DB")`.
      """)
    end
```

- [ ] **Step 4: Run the test file again and confirm everything passes**

Run: `mix test test/mix/tasks/hgs_surrealdb_sdk_install_test.exs`
Expected: PASS (all six tests).

- [ ] **Step 5: Commit**

```bash
git add lib/mix/tasks/hgs_surrealdb_sdk.install.ex test/mix/tasks/hgs_surrealdb_sdk_install_test.exs
git commit -m "feat: auto-provision the SurrealDB namespace/database on install"
```

---

### Task 4: Update README documentation

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: behavior implemented in Tasks 1-3 (auto-detect registry, automatic provisioning task).
- Produces: none (documentation only — no other task depends on this).

- [ ] **Step 1: Update the "Igniter" section**

In `README.md`, replace:
```markdown
The installer adds the dependency, creates a `SurrealDB.Store` module, wires it
into your supervision tree, and writes starter config.
```

With:
```markdown
The installer adds the dependency, creates a `SurrealDB.Store` module, wires it
into your supervision tree, writes starter config, and registers the store
under `config :my_app, :surrealdb_stores, [...]`. Once you confirm the
generated changes, it also runs `mix surreal_db.create --store
MyApp.SurrealStore` automatically to create the target namespace/database — if
the server isn't reachable yet, just run that command yourself once it is up.

Because the store is registered, any `surreal_db.*` task run later from the
same app auto-detects it, so `--store` can be omitted as long as it's the only
registered store.
```

- [ ] **Step 2: Add a note to the "Migrations" section**

In `README.md`, replace:
```markdown
See [Migrations](docs/migrations.md) for task options, registry behavior, and
rollback notes.
```

With:
```markdown
`--store` can be omitted from any of the commands above once a single
`SurrealDB.Store` is registered under `:surrealdb_stores` (e.g. via the
Igniter installer above) — the task auto-detects it.

See [Migrations](docs/migrations.md) for task options, registry behavior, and
rollback notes.
```

- [ ] **Step 3: Run the full test suite as a final sanity check**

Run: `mix test`
Expected: PASS (no regressions across the whole suite).

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document automatic namespace/database provisioning and store auto-detection"
```
