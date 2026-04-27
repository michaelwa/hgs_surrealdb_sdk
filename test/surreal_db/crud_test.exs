defmodule SurrealDB.CrudTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.QueryResult

  test "select/2 table query generation" do
    client =
      client_with_adapter(fn request ->
        assert request.body == "SELECT * FROM person"
        ok_response(request)
      end)

    assert {:ok, %QueryResult{statuses: ["OK"]}} = SurrealDB.select(client, "person")
  end

  test "select/2 record query generation" do
    client =
      client_with_adapter(fn request ->
        assert request.body == "SELECT * FROM person:john"
        ok_response(request)
      end)

    assert {:ok, %QueryResult{statuses: ["OK"]}} = SurrealDB.select(client, "person:john")
  end

  test "create/3 delegates with data safely" do
    client =
      client_with_adapter(fn request ->
        assert String.starts_with?(request.body, "CREATE person CONTENT ")

        assert_json_tail(request.body, "CREATE person CONTENT ", %{
          "name" => "John",
          "active" => true
        })

        ok_response(request)
      end)

    assert {:ok, %QueryResult{statuses: ["OK"]}} =
             SurrealDB.create(client, "person", %{name: "John", active: true})
  end

  test "update/3 delegates with data safely" do
    client =
      client_with_adapter(fn request ->
        assert String.starts_with?(request.body, "UPDATE person:john CONTENT ")
        assert_json_tail(request.body, "UPDATE person:john CONTENT ", %{"name" => "John Doe"})
        ok_response(request)
      end)

    assert {:ok, %QueryResult{statuses: ["OK"]}} =
             SurrealDB.update(client, "person:john", %{name: "John Doe"})
  end

  test "merge/3 delegates with data safely" do
    client =
      client_with_adapter(fn request ->
        assert String.starts_with?(request.body, "UPDATE person:john MERGE ")
        assert_json_tail(request.body, "UPDATE person:john MERGE ", %{"active" => true})
        ok_response(request)
      end)

    assert {:ok, %QueryResult{statuses: ["OK"]}} =
             SurrealDB.merge(client, "person:john", %{active: true})
  end

  test "patch/3 delegates with data safely" do
    client =
      client_with_adapter(fn request ->
        assert String.starts_with?(request.body, "UPDATE person:john PATCH ")

        assert_json_tail(request.body, "UPDATE person:john PATCH ", [
          %{"op" => "replace", "path" => "/name", "value" => "Jane"}
        ])

        ok_response(request)
      end)

    assert {:ok, %QueryResult{statuses: ["OK"]}} =
             SurrealDB.patch(client, "person:john", [
               %{op: "replace", path: "/name", value: "Jane"}
             ])
  end

  test "delete/2 query generation" do
    client =
      client_with_adapter(fn request ->
        assert request.body == "DELETE person:john"
        ok_response(request)
      end)

    assert {:ok, %QueryResult{statuses: ["OK"]}} = SurrealDB.delete(client, "person:john")
  end

  test "invalid identifiers return structured errors" do
    client =
      %Client{
        endpoint: "http://localhost:8000",
        namespace: "test",
        database: "app",
        auth: {:basic, %{username: "root", password: "root"}}
      }

    assert {:error, %Error{type: :invalid_identifier}} = SurrealDB.select(client, "person; DROP")
    assert {:error, %Error{type: :invalid_identifier}} = SurrealDB.create(client, "person*", %{})
  end

  test "crud functions preserve error style" do
    client =
      client_with_adapter(fn request ->
        {request, Req.Response.new(status: 401, body: ~s({"error":"unauthorized"}))}
      end)

    assert {:error, %Error{type: :http_error}} = SurrealDB.delete(client, "person:john")
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

  defp ok_response(request) do
    {request, Req.Response.new(status: 200, body: ~s([{"status":"OK","result":[]}]))}
  end

  defp assert_json_tail(body, prefix, expected) do
    json = String.replace_prefix(body, prefix, "")
    assert Jason.decode!(json) == expected
  end
end
