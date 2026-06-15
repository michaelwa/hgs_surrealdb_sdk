defmodule SurrealDB.ConfigTest do
  use ExUnit.Case, async: false

  alias SurrealDB.Client
  alias SurrealDB.Error

  setup do
    original = Application.get_env(:hgs_surrealdb_sdk, :connection)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:hgs_surrealdb_sdk, :connection)
      else
        Application.put_env(:hgs_surrealdb_sdk, :connection, original)
      end
    end)

    :ok
  end

  test "valid config creates a client" do
    assert {:ok, %Client{} = client} =
             SurrealDB.connect(
               endpoint: "http://localhost:8000/",
               namespace: "test",
               database: "app",
               username: "root",
               password: "root"
             )

    assert client.endpoint == "http://localhost:8000"
    assert client.namespace == "test"
    assert client.database == "app"
    assert client.auth == {:basic, %{username: "root", password: "root"}}
  end

  test "missing endpoint returns error" do
    assert {:error, %Error{type: :invalid_config, details: %{missing: missing}}} =
             SurrealDB.connect(namespace: "test", database: "app", anonymous: true)

    assert :endpoint in missing
  end

  test "missing namespace returns error" do
    assert {:error, %Error{type: :invalid_config, details: %{missing: [:namespace]}}} =
             SurrealDB.connect(
               endpoint: "http://localhost:8000",
               database: "app",
               anonymous: true
             )
  end

  test "missing database returns error" do
    assert {:error, %Error{type: :invalid_config, details: %{missing: [:database]}}} =
             SurrealDB.connect(
               endpoint: "http://localhost:8000",
               namespace: "test",
               anonymous: true
             )
  end

  test "rejects conflicting auth options" do
    assert {:error, %Error{type: :invalid_config}} =
             SurrealDB.connect(
               endpoint: "http://localhost:8000",
               namespace: "test",
               database: "app",
               username: "root",
               password: "root",
               auth_token: "abc"
             )
  end

  test "requires explicit anonymous opt in" do
    assert {:error, %Error{type: :invalid_config, message: message}} =
             SurrealDB.connect(
               endpoint: "http://localhost:8000",
               namespace: "test",
               database: "app"
             )

    assert message =~ "anonymous: true"
  end

  test "allows anonymous only when explicitly configured" do
    assert {:ok, %Client{auth: nil, anonymous?: true}} =
             SurrealDB.connect(
               endpoint: "http://localhost:8000",
               namespace: "test",
               database: "app",
               anonymous: true
             )
  end

  test "zero arity connect uses application connection config" do
    Application.put_env(:hgs_surrealdb_sdk, :connection,
      endpoint: "http://configured:8000/",
      namespace: "configured_ns",
      database: "configured_db",
      anonymous: true
    )

    assert {:ok, %Client{} = client} = SurrealDB.connect()
    assert client.endpoint == "http://configured:8000"
    assert client.namespace == "configured_ns"
    assert client.database == "configured_db"
    assert client.anonymous? == true
  end

  test "rejects an unknown transport" do
    opts = [
      endpoint: "http://localhost:8000",
      namespace: "ns",
      database: "db",
      username: "root",
      password: "root",
      transport: :websockets
    ]

    assert {:error, %SurrealDB.Error{type: :invalid_config}} = SurrealDB.Config.build_client(opts)
  end

  test "application connection config is required" do
    Application.delete_env(:hgs_surrealdb_sdk, :connection)

    assert {:error, %Error{type: :invalid_config, message: message, details: details}} =
             SurrealDB.connect()

    assert message == "missing application connection config"
    assert details == %{app: :hgs_surrealdb_sdk, key: :connection}
  end
end
