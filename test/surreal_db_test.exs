defmodule SurrealDBTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.QueryResult

  describe "connect/1" do
    test "builds a client with normalized endpoint and basic auth" do
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

    test "rejects missing required options" do
      assert {:error, %Error{type: :validation, details: %{missing: missing}}} =
               SurrealDB.connect(namespace: "test")

      assert :endpoint in missing
      assert :database in missing
    end

    test "rejects conflicting auth options" do
      assert {:error, %Error{type: :validation}} =
               SurrealDB.connect(
                 endpoint: "http://localhost:8000",
                 namespace: "test",
                 database: "app",
                 username: "root",
                 password: "root",
                 auth_token: "abc"
               )
    end
  end

  describe "query/2" do
    test "executes a query and returns a normalized query result" do
      client =
        client_with_adapter(fn request ->
          assert request.method == :post
          assert URI.to_string(request.url) == "http://localhost:8000/sql"
          assert Req.Request.get_header(request, "ns") == ["test"]
          assert Req.Request.get_header(request, "db") == ["app"]
          assert Req.Request.get_header(request, "authorization") == [basic_auth("root", "root")]
          assert request.body == "SELECT * FROM person"

          {request,
           Req.Response.new(
             status: 200,
             body: ~s([{"status":"OK","time":"12ms","result":[{"id":"person:one"}]}])
           )}
        end)

      assert {:ok, %QueryResult{} = result} = SurrealDB.query(client, "SELECT * FROM person")
      assert result.status == :ok
      assert result.time == "12ms"
      assert result.result == [%{"id" => "person:one"}]
      assert [%{status: :ok}] = result.statements
    end

    test "supports bearer token auth" do
      client =
        %Client{
          endpoint: "http://localhost:8000",
          namespace: "test",
          database: "app",
          auth: {:bearer, "token-123"},
          request_options: [adapter: &assert_bearer_request/1]
        }

      assert {:ok, %QueryResult{status: :ok}} = SurrealDB.query(client, "INFO FOR DB")
    end

    test "returns structured error for surreal query failures" do
      client =
        client_with_adapter(fn request ->
          {request,
           Req.Response.new(
             status: 200,
             body: ~s([{"status":"ERR","time":"1ms","detail":"Parse failure"}])
           )}
        end)

      assert {:error, %Error{type: :surreal, message: "Parse failure"}} =
               SurrealDB.query(client, "BAD QUERY")
    end

    test "returns structured error for non-success http responses" do
      client =
        client_with_adapter(fn request ->
          {request, Req.Response.new(status: 401, body: ~s({"error":"unauthorized"}))}
        end)

      assert {:error, %Error{type: :http, status: 401, details: %{error: "unauthorized"}}} =
               SurrealDB.query(client, "SELECT * FROM person")
    end

    test "returns structured error for request failures" do
      client =
        client_with_adapter(fn request ->
          {request, RuntimeError.exception("connection refused")}
        end)

      assert {:error, %Error{type: :request, message: "connection refused"}} =
               SurrealDB.query(client, "SELECT * FROM person")
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

  defp assert_bearer_request(request) do
    assert Req.Request.get_header(request, "authorization") == ["Bearer token-123"]
    {request, Req.Response.new(status: 200, body: ~s([{"status":"OK","result":{"ok":true}}]))}
  end

  defp basic_auth(username, password) do
    "Basic " <> Base.encode64("#{username}:#{password}")
  end
end
