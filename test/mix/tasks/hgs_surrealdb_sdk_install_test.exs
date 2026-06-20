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
      password: "root"
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
      password: "root"
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
end
