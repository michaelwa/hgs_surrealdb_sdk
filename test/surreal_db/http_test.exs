defmodule SurrealDB.HTTPTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.QueryResult

  test "successful response parses into query result" do
    client =
      client_with_adapter(fn request ->
        assert request.method == :post
        assert URI.to_string(request.url) == "http://localhost:8000/sql"
        assert Req.Request.get_header(request, "ns") == ["test"]
        assert Req.Request.get_header(request, "db") == ["app"]
        assert Req.Request.get_header(request, "authorization") == [basic_auth("root", "root")]
        assert Req.Request.get_header(request, "content-type") == ["text/plain"]
        assert request.body == "SELECT * FROM person"

        {request,
         Req.Response.new(
           status: 200,
           body: ~s([{"status":"OK","time":"12ms","result":[{"id":"person:one"}]}])
         )}
      end)

    assert {:ok, %QueryResult{} = result} = SurrealDB.query(client, "SELECT * FROM person")
    assert result.results == [[%{"id" => "person:one"}]]
    assert result.statuses == ["OK"]
    assert is_list(result.raw)
  end

  test "transport status failures become structured errors" do
    client =
      client_with_adapter(fn request ->
        {request, Req.Response.new(status: 401, body: ~s({"error":"unauthorized"}))}
      end)

    assert {:error, %Error{type: :transport_error, status: 401}} =
             SurrealDB.rpc(client, "query", ["SELECT * FROM person"])
  end

  test "json decode failure becomes structured error" do
    client =
      client_with_adapter(fn request ->
        {request, Req.Response.new(status: 200, body: "{not-json")}
      end)

    assert {:error, %Error{type: :rpc_decode_error}} =
             SurrealDB.rpc(client, "query", ["SELECT * FROM person"])
  end

  test "surreal query error remains structured on public query api" do
    client =
      client_with_adapter(fn request ->
        {request,
         Req.Response.new(
           status: 200,
           body: ~s([{"status":"ERR","time":"1ms","detail":"Parse failure"}])
         )}
      end)

    assert {:error, %Error{type: :surreal_error, message: "Parse failure"}} =
             SurrealDB.query(client, "BAD QUERY")
  end

  test "request failures become transport errors" do
    client =
      client_with_adapter(fn request ->
        {request, RuntimeError.exception("connection refused")}
      end)

    assert {:error, %Error{type: :transport_error, message: "connection refused"}} =
             SurrealDB.rpc(client, "query", ["SELECT * FROM person"])
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

    assert {:ok, %QueryResult{statuses: ["OK"]}} = SurrealDB.query(client, "INFO FOR DB")
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
