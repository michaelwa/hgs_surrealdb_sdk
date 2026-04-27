defmodule SurrealDB.RPCTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.RPC
  alias SurrealDB.RPC.Request
  alias SurrealDB.RPC.Response
  alias SurrealDB.Transport.HTTP

  test "rpc request struct creation includes ids" do
    request = Request.new("query", ["SELECT * FROM person"])

    assert request.method == "query"
    assert request.params == ["SELECT * FROM person"]
    assert is_integer(request.id)
    assert request.id > 0
  end

  test "request ids are present and monotonic enough for repeated calls" do
    first = Request.new("query", [])
    second = Request.new("query", [])

    assert first.id < second.id
  end

  test "http transport builds rpc request body from query params" do
    client =
      client_with_adapter(fn request ->
        assert request.body == ~s(SELECT * FROM person WHERE active = true)
        {request, Req.Response.new(status: 200, body: ~s([{"status":"OK","result":[]}]))}
      end)

    request = %Request{
      id: 10,
      method: "query",
      params: ["SELECT * FROM person WHERE active = $active", %{active: true}]
    }

    assert {:ok, %Response{id: 10, result: [_]}} = HTTP.call(client, request)
  end

  test "rpc success response mapping" do
    client =
      client_with_adapter(fn request ->
        {request, Req.Response.new(status: 200, body: ~s([{"status":"OK","result":[1]}]))}
      end)

    assert {:ok, %Response{id: id, result: [%{"result" => [1], "status" => "OK"}], error: nil}} =
             RPC.call(client, "query", ["RETURN 1"])

    assert is_integer(id)
  end

  test "rpc error response mapping" do
    client =
      client_with_adapter(fn request ->
        {request,
         Req.Response.new(
           status: 200,
           body:
             ~s({"error":{"code":"RPC_QUERY_FAILED","message":"query rejected","detail":"bad query"}})
         )}
      end)

    assert {:error, %Error{type: :rpc_error, code: "RPC_QUERY_FAILED", message: "query rejected"}} =
             RPC.call(client, "query", ["BAD QUERY"])
  end

  test "unsupported rpc methods return structured errors" do
    client =
      %Client{
        endpoint: "http://localhost:8000",
        namespace: "test",
        database: "app",
        auth: {:basic, %{username: "root", password: "root"}}
      }

    assert {:error, %Error{type: :rpc_error}} = RPC.call(client, "signin", [%{user: "root"}])
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
end
