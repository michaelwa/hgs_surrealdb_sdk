defmodule SurrealDBTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.QueryResult

  test "public api returns tuples, not raised exceptions" do
    client =
      %Client{
        endpoint: "http://localhost:8000",
        namespace: "test",
        database: "app",
        auth: {:basic, %{username: "root", password: "root"}},
        request_options: [
          adapter: fn request ->
            {request, Req.Response.new(status: 200, body: ~s([{"status":"OK","result":[1]}]))}
          end
        ]
      }

    assert {:ok, %QueryResult{results: [[1]]}} = SurrealDB.query(client, "RETURN 1")
  end

  test "query variables api returns structured error until implemented" do
    client =
      %Client{
        endpoint: "http://localhost:8000",
        namespace: "test",
        database: "app",
        auth: {:basic, %{username: "root", password: "root"}}
      }

    assert {:error, %Error{type: :http_error, message: message}} =
             SurrealDB.query(client, "SELECT * FROM person WHERE age > $age", %{age: 30})

    assert message =~ "not implemented"
  end
end
