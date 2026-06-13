defmodule SurrealDB.Repo.IntegrationTest do
  @moduledoc """
  End-to-end example: declare a schema, then create/get/find/update/delete it
  through `SurrealDB.Repo` against a stubbed transport.
  """
  use ExUnit.Case, async: true

  alias SurrealDB.{Client, Repo}

  defmodule Account do
    use SurrealDB.Schema

    table "account"

    schema do
      Zoi.object(%{
        id: Zoi.string() |> Zoi.optional(),
        owner: Zoi.string(),
        balance: Zoi.integer()
      })
    end
  end

  defp client_returning(records) do
    %Client{
      endpoint: "http://localhost:8000",
      namespace: "test",
      database: "app",
      auth: {:basic, %{username: "root", password: "root"}},
      request_options: [
        adapter: fn request ->
          body = Jason.encode!([%{"status" => "OK", "result" => records}])
          {request, Req.Response.new(status: 200, body: body)}
        end
      ]
    }
  end

  test "create -> get -> find -> update -> delete round-trip hydrates structs" do
    created = %{"id" => "account:1", "owner" => "jane", "balance" => 100}

    assert {:ok, %Account{id: "account:1", owner: "jane", balance: 100}} =
             Repo.create(client_returning([created]), Account, %{owner: "jane", balance: 100})

    assert {:ok, %Account{owner: "jane"}} =
             Repo.get(client_returning([created]), Account, "account:1")

    assert {:ok, %Account{owner: "jane"}} =
             Repo.find(client_returning([created]), Account, %{owner: "jane"})

    updated = %{created | "balance" => 250}

    assert {:ok, %Account{balance: 250}} =
             Repo.update(client_returning([updated]), Account, "account:1", %{balance: 250})

    assert {:ok, %Account{id: "account:1"}} =
             Repo.delete(client_returning([created]), Account, "account:1")
  end
end
