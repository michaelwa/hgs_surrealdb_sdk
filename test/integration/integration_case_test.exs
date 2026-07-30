defmodule SurrealDB.IntegrationCaseTest do
  use SurrealDB.IntegrationCase, async: false

  alias SurrealDB.Client

  @integration_variables [
    "SURREALDB_INTEGRATION_ENDPOINT",
    "SURREALDB_INTEGRATION_WS_ENDPOINT",
    "SURREALDB_INTEGRATION_USERNAME",
    "SURREALDB_INTEGRATION_PASSWORD",
    "SURREALDB_INTEGRATION_NAMESPACE",
    "SURREALDB_INTEGRATION_DATABASE"
  ]

  @moduletag :integration

  test "local defaults are accepted" do
    clear_integration_variables()

    assert %Client{
             endpoint: "http://127.0.0.1:18000",
             namespace: "hgs_sdk_integration",
             database: "hgs_sdk_integration"
           } = integration_client()

    assert %Client{
             endpoint: "ws://127.0.0.1:18000/rpc",
             namespace: "hgs_sdk_integration",
             database: "hgs_sdk_integration",
             connection: connection
           } = integration_ws_client()

    assert is_pid(connection)
  end

  test "external endpoint requires explicit opt-in" do
    original_endpoint = System.get_env("SURREALDB_INTEGRATION_ENDPOINT")
    System.put_env("SURREALDB_INTEGRATION_ENDPOINT", "https://example.com")

    on_exit(fn ->
      if original_endpoint do
        System.put_env("SURREALDB_INTEGRATION_ENDPOINT", original_endpoint)
      else
        System.delete_env("SURREALDB_INTEGRATION_ENDPOINT")
      end
    end)

    error =
      assert_raise ArgumentError, fn ->
        integration_client()
      end

    assert Exception.message(error) =~ "SURREALDB_INTEGRATION_ALLOW_EXTERNAL=1"
  end

  test "integration scope is a unique SurrealQL identifier" do
    assert integration_scope() =~ ~r/^it_[0-9]+$/
    refute integration_scope() == integration_scope()
  end

  defp clear_integration_variables do
    original_values = Map.new(@integration_variables, &{&1, System.get_env(&1)})

    Enum.each(@integration_variables, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(original_values, fn
        {variable, nil} -> System.delete_env(variable)
        {variable, value} -> System.put_env(variable, value)
      end)
    end)
  end
end
