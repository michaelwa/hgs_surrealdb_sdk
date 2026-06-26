defmodule Mix.Tasks.HgsSurrealdbSdk.InstallTest do
  use ExUnit.Case, async: true
  import Igniter.Test

  test "generates a store module" do
    test_project()
    |> Igniter.compose_task("hgs_surrealdb_sdk.install", [])
    |> assert_creates("lib/test/surreal_store.ex", """
    defmodule Test.SurrealStore do
      use SurrealDB.Store, otp_app: :test
    end
    """)
  end

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
      password: "root",
      repo_path: "priv/surreal_repo"
    """)
  end

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
      password: "root",
      repo_path: "priv/surreal_repo"
    """)
  end

  test "scaffolds the SurrealDB repo directory" do
    test_project()
    |> Igniter.compose_task("hgs_surrealdb_sdk.install", [])
    |> assert_creates("priv/surreal_repo/migrations/.gitkeep", """
    # Keep this directory in version control.
    """)
    |> assert_creates("priv/surreal_repo/seeds.exs", """
    # Seed script for the SurrealDB store. Run with: mix surreal.seed
    # The store API is available, e.g.:
    #
    #   Test.SurrealStore.create(MyApp.User, %{name: "Jane"})
    """)
  end

  test "adds the store to the application supervision tree" do
    test_project()
    |> Igniter.compose_task("hgs_surrealdb_sdk.install", [])
    |> assert_creates("lib/test/application.ex", """
    defmodule Test.Application do
      @moduledoc false

      use Application

      @impl true
      def start(_type, _args) do
        children = [Test.SurrealStore]

        opts = [strategy: :one_for_one, name: Test.Supervisor]
        Supervisor.start_link(children, opts)
      end
    end
    """)
  end

  test "queues mix surreal.create with the generated store" do
    test_project()
    |> Igniter.compose_task("hgs_surrealdb_sdk.install", [])
    |> assert_has_task("surreal.create", ["--store", "Test.SurrealStore"])
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
      notice =~ "mix surreal.create --store Test.SurrealStore" and
        notice =~ ~s("app2/app2" namespace/database) and
        notice =~ "priv/surreal_repo/migrations" and
        notice =~ "mix surreal.seed" and
        notice =~ "schema_migrations"
    end)
  end
end
