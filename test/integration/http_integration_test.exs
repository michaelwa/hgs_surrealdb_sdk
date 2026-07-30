defmodule SurrealDB.HTTPIntegrationTest do
  use SurrealDB.IntegrationCase

  alias SurrealDB.{Error, QueryResult}

  @moduletag :integration

  setup do
    client = integration_client()
    table = integration_table("people")

    assert {:ok, %QueryResult{}} =
             SurrealDB.query(client, "DEFINE TABLE #{table} SCHEMALESS;")

    %{client: client, table: table, record: "#{table}:jane"}
  end

  test "query executes literal and parameterized SurrealQL and returns query errors", %{
    client: client
  } do
    assert {:ok, %QueryResult{results: [1]}} = SurrealDB.query(client, "RETURN 1")

    assert {:ok, %QueryResult{results: [%{"name" => "Jane"}]}} =
             SurrealDB.query(client, "RETURN { name: $name }", %{name: "Jane"})

    assert {:error, %Error{type: :surreal_error}} =
             SurrealDB.query(client, ~s(THROW "integration query error"))
  end

  test "CRUD helpers operate on the isolated table", %{
    client: client,
    table: table,
    record: record
  } do
    assert {:ok, %QueryResult{results: [[%{"id" => ^record, "name" => "Jane", "age" => 30}]]}} =
             SurrealDB.create(client, record, %{name: "Jane", age: 30})

    assert {:ok, %QueryResult{results: [[%{"id" => ^record, "name" => "Jane", "age" => 30}]]}} =
             SurrealDB.select(client, table)

    assert {:ok, %QueryResult{results: [[%{"id" => ^record, "name" => "Jane", "age" => 31}]]}} =
             SurrealDB.merge(client, record, %{age: 31})

    assert {:ok, %QueryResult{results: [[%{"id" => ^record, "name" => "Janet", "age" => 31}]]}} =
             SurrealDB.patch(client, record, [
               %{op: "replace", path: "/name", value: "Janet"}
             ])

    assert {:ok, %QueryResult{results: [[]]}} = SurrealDB.delete(client, record)

    assert {:ok, %QueryResult{results: [[]]}} = SurrealDB.select(client, table)
  end
end
