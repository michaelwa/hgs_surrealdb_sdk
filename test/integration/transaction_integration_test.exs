defmodule SurrealDB.TransactionIntegrationTest do
  use SurrealDB.IntegrationCase

  alias SurrealDB.{Multi, QueryResult, Repo}

  @moduletag :integration
  @table "it_transaction_people"

  defmodule Person do
    use SurrealDB.Schema

    table("it_transaction_people")

    schema do
      Zoi.object(%{
        id: Zoi.string() |> Zoi.optional(),
        name: Zoi.string(),
        email: Zoi.string()
      })
    end
  end

  setup do
    client = integration_client()
    assert {:ok, %QueryResult{}} = SurrealDB.query(client, "REMOVE TABLE IF EXISTS #{@table};")
    assert {:ok, %QueryResult{}} = SurrealDB.query(client, "DEFINE TABLE #{@table} SCHEMALESS;")

    on_exit(fn ->
      assert {:ok, %QueryResult{}} = SurrealDB.query(client, "REMOVE TABLE IF EXISTS #{@table};")
    end)

    %{client: client}
  end

  test "transaction commits typed steps and returns hydrated values", %{client: client} do
    multi =
      Multi.new()
      |> Multi.create(:first, Person, %{name: "Jane", email: "jane@example.com"})
      |> Multi.create(:second, Person, %{name: "John", email: "john@example.com"})

    assert {:ok, %{first: %Person{name: "Jane"}, second: %Person{name: "John"}}} =
             SurrealDB.transaction(client, multi)

    assert {:ok, [%Person{}, %Person{}]} = Repo.all(client, Person)
  end

  test "transaction rolls back earlier writes when a later step throws", %{client: client} do
    multi =
      Multi.new()
      |> Multi.create(:first, Person, %{name: "First", email: "first@example.com"})
      |> Multi.raw(:fail, "THROW 'intentional integration rollback'")

    assert {:error, :fail, %SurrealDB.Error{}} = SurrealDB.transaction(client, multi)
    assert {:ok, nil} = Repo.find(client, Person, %{email: "first@example.com"})
  end
end
