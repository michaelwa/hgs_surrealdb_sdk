defmodule SurrealDB.ConfigTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Client
  alias SurrealDB.Error

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
end
