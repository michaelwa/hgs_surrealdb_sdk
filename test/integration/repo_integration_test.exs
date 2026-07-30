defmodule SurrealDB.RepoIntegrationTest do
  use SurrealDB.IntegrationCase

  alias SurrealDB.{QueryResult, Repo}

  @moduletag :integration
  @table "it_repo_people"

  defmodule Person do
    use SurrealDB.Schema

    table("it_repo_people")

    schema do
      Zoi.object(%{
        id: Zoi.string() |> Zoi.optional(),
        name: Zoi.string(),
        age: Zoi.integer()
      })
    end
  end

  setup do
    client = integration_client()

    assert {:ok, %QueryResult{}} =
             SurrealDB.query(client, "REMOVE TABLE IF EXISTS #{@table};")

    assert {:ok, %QueryResult{}} =
             SurrealDB.query(client, "DEFINE TABLE #{@table} SCHEMALESS;")

    on_exit(fn ->
      assert {:ok, %QueryResult{}} =
               SurrealDB.query(client, "REMOVE TABLE IF EXISTS #{@table};")
    end)

    %{client: client}
  end

  test "Repo persists records and hydrates the schema struct", %{client: client} do
    assert {:ok, %Person{id: id, name: "Jane", age: 30}} =
             Repo.create(client, Person, %{name: "Jane", age: 30})

    assert {:ok, %Person{id: ^id, name: "Jane", age: 30}} = Repo.get(client, Person, id)

    assert {:ok, [%Person{id: ^id, name: "Jane", age: 30}]} = Repo.all(client, Person)

    assert {:ok, %Person{id: ^id, name: "Jane", age: 30}} =
             Repo.find(client, Person, %{name: "Jane"})

    assert {:ok, %Person{id: ^id, name: "Jane", age: 31}} =
             Repo.update(client, Person, id, %{age: 31})

    assert {:ok, %Person{id: ^id, name: "Jane", age: 31}} = Repo.delete(client, Person, id)
  end

  test "Repo returns nil for missing records and rejects invalid identifiers", %{client: client} do
    assert {:ok, nil} = Repo.get(client, Person, "#{@table}:missing")

    assert {:error, %SurrealDB.Error{type: :invalid_identifier}} =
             Repo.get(client, Person, "#{@table}; DROP")
  end
end
