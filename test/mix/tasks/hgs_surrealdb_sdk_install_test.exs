defmodule Mix.Tasks.HgsSurrealdbSdk.InstallTest do
  use ExUnit.Case, async: false
  import Igniter.Test

  test "scaffolds default :connection config under :hgs_surrealdb_sdk" do
    igniter =
      test_project()
      |> Igniter.compose_task("hgs_surrealdb_sdk.install", [])

    source = config_source(igniter)

    assert source =~ "config :hgs_surrealdb_sdk"
    assert source =~ "connection:"
    assert source =~ ~s(endpoint: "http://localhost:8000")
    assert source =~ ~s(namespace: "test")
    assert source =~ ~s(database: "test")
    assert source =~ ~s(username: "root")
    assert source =~ ~s(password: "root")
  end

  test "honors provided endpoint/namespace/database options" do
    igniter =
      test_project()
      |> Igniter.compose_task("hgs_surrealdb_sdk.install", [
        "--endpoint",
        "http://db.internal:8000",
        "--namespace",
        "app",
        "--database",
        "app"
      ])

    source = config_source(igniter)

    assert source =~ ~s(endpoint: "http://db.internal:8000")
    assert source =~ ~s(namespace: "app")
    assert source =~ ~s(database: "app")
  end

  # Read the rendered config/config.exs from the igniter's in-memory file set.
  defp config_source(igniter) do
    igniter.rewrite
    |> Rewrite.source!("config/config.exs")
    |> Rewrite.Source.get(:content)
  end
end
