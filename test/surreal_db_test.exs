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

  test "query variables are rendered safely before dispatch" do
    client =
      %Client{
        endpoint: "http://localhost:8000",
        namespace: "test",
        database: "app",
        auth: {:basic, %{username: "root", password: "root"}},
        request_options: [
          adapter: fn request ->
            assert request.body ==
                     ~s(SELECT * FROM person WHERE age > 30 AND active = true AND name = "Jane")

            {request, Req.Response.new(status: 200, body: ~s([{"status":"OK","result":[]}]))}
          end
        ]
      }

    assert {:ok, %QueryResult{statuses: ["OK"]}} =
             SurrealDB.query(
               client,
               "SELECT * FROM person WHERE age > $age AND active = $active AND name = $name",
               %{age: 30, active: true, name: "Jane"}
             )
  end

  test "invalid variable keys return structured errors" do
    client =
      %Client{
        endpoint: "http://localhost:8000",
        namespace: "test",
        database: "app",
        auth: {:basic, %{username: "root", password: "root"}}
      }

    assert {:error, %Error{type: :invalid_variables}} =
             SurrealDB.query(client, "SELECT * FROM person WHERE age > $age", %{"bad-key" => 30})
  end
end
