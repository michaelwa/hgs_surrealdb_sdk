defmodule SurrealDB.RepoTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Client
  alias SurrealDB.Repo
  alias SurrealDB.Schema.ValidationError

  defmodule User do
    use SurrealDB.Schema

    table "user"

    schema do
      Zoi.object(%{
        id: Zoi.string() |> Zoi.optional(),
        name: Zoi.string(),
        email: Zoi.string(),
        age: Zoi.integer() |> Zoi.optional()
      })
    end
  end

  defp client_with_adapter(adapter) do
    %Client{
      endpoint: "http://localhost:8000",
      namespace: "test",
      database: "app",
      auth: {:basic, %{username: "root", password: "root"}},
      request_options: [adapter: adapter]
    }
  end

  defp records_response(request, records) do
    body = Jason.encode!([%{"status" => "OK", "result" => records}])
    {request, Req.Response.new(status: 200, body: body)}
  end

  defp assert_json_tail(body, prefix, expected) do
    json = String.replace_prefix(body, prefix, "")
    assert Jason.decode!(json) == expected
  end

  @jane %{"id" => "user:abc", "name" => "Jane", "email" => "jane@example.com"}

  test "get/3 selects by id and hydrates a struct" do
    client =
      client_with_adapter(fn request ->
        assert request.body == "SELECT * FROM user:abc"
        records_response(request, [@jane])
      end)

    assert {:ok, %User{id: "user:abc", name: "Jane", email: "jane@example.com"}} =
             Repo.get(client, User, "user:abc")
  end

  test "get/3 returns {:ok, nil} when nothing is found" do
    client =
      client_with_adapter(fn request -> records_response(request, []) end)

    assert {:ok, nil} = Repo.get(client, User, "user:zzz")
  end

  test "get/3 rejects an invalid record id without touching the network" do
    client =
      client_with_adapter(fn _request -> raise "network must not be called" end)

    assert {:error, %SurrealDB.Error{type: :invalid_identifier}} =
             Repo.get(client, User, "user; DROP")
  end

  test "all/2 selects the whole table and hydrates a list" do
    client =
      client_with_adapter(fn request ->
        assert request.body == "SELECT * FROM type::table(\"user\")"
        records_response(request, [@jane])
      end)

    assert {:ok, [%User{name: "Jane"}]} = Repo.all(client, User)
  end

  test "all/3 applies equality filters" do
    client =
      client_with_adapter(fn request ->
        assert request.body ==
                 "SELECT * FROM type::table(\"user\") WHERE email = \"jane@example.com\""

        records_response(request, [@jane])
      end)

    assert {:ok, [%User{}]} = Repo.all(client, User, %{email: "jane@example.com"})
  end

  test "all/3 does not let a filter field named `table` clobber the table binding" do
    client =
      client_with_adapter(fn request ->
        assert request.body == "SELECT * FROM type::table(\"user\") WHERE table = \"5\""
        records_response(request, [@jane])
      end)

    assert {:ok, [%User{}]} = Repo.all(client, User, %{table: "5"})
  end

  test "find/3 adds LIMIT 1 and returns a single struct" do
    client =
      client_with_adapter(fn request ->
        assert request.body ==
                 "SELECT * FROM type::table(\"user\") WHERE email = \"jane@example.com\" LIMIT 1"

        records_response(request, [@jane])
      end)

    assert {:ok, %User{name: "Jane"}} =
             Repo.find(client, User, %{email: "jane@example.com"})
  end

  test "create/3 validates then issues a parameterized CREATE" do
    client =
      client_with_adapter(fn request ->
        assert String.starts_with?(request.body, "CREATE type::table(\"user\") CONTENT ")

        assert_json_tail(request.body, "CREATE type::table(\"user\") CONTENT ", %{
          "name" => "Jane",
          "email" => "jane@example.com"
        })

        records_response(request, [@jane])
      end)

    assert {:ok, %User{name: "Jane"}} =
             Repo.create(client, User, %{name: "Jane", email: "jane@example.com"})
  end

  test "create/3 returns a ValidationError without touching the network" do
    client =
      client_with_adapter(fn _request -> raise "network must not be called" end)

    assert {:error, %ValidationError{}} = Repo.create(client, User, %{name: "Jane"})
  end

  test "update/4 issues a parameterized MERGE" do
    client =
      client_with_adapter(fn request ->
        assert String.starts_with?(request.body, "UPDATE user:abc MERGE ")
        assert_json_tail(request.body, "UPDATE user:abc MERGE ", %{"age" => 42})
        records_response(request, [Map.put(@jane, "age", 42)])
      end)

    assert {:ok, %User{age: 42}} = Repo.update(client, User, "user:abc", %{age: 42})
  end

  test "delete/3 issues DELETE ... RETURN BEFORE and returns the prior struct" do
    client =
      client_with_adapter(fn request ->
        assert request.body == "DELETE user:abc RETURN BEFORE"
        records_response(request, [@jane])
      end)

    assert {:ok, %User{id: "user:abc"}} = Repo.delete(client, User, "user:abc")
  end

  test "query/4 runs raw SurrealQL and hydrates results" do
    client =
      client_with_adapter(fn request ->
        assert request.body == "SELECT * FROM type::table(\"user\")"
        records_response(request, [@jane])
      end)

    assert {:ok, [%User{name: "Jane"}]} =
             Repo.query(client, User, "SELECT * FROM type::table($table)", %{table: "user"})
  end

  test "query errors are returned as SurrealDB.Error" do
    client =
      client_with_adapter(fn request ->
        {request, Req.Response.new(status: 401, body: ~s({"error":"unauthorized"}))}
      end)

    assert {:error, %SurrealDB.Error{}} = Repo.get(client, User, "user:abc")
  end
end
