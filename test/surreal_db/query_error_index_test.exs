defmodule SurrealDB.QueryErrorIndexTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Client

  @failed "The query was not executed due to a failed transaction"
  @cancelled "The query was not executed due to a cancelled transaction"
  @commit_aborted "Cannot COMMIT: the transaction was aborted due to a prior error"

  defp client_with_response(statements) do
    %Client{
      endpoint: "http://localhost:8000",
      namespace: "test",
      database: "app",
      auth: {:basic, %{username: "root", password: "root"}},
      request_options: [
        adapter: fn request ->
          {request, Req.Response.new(status: 200, body: Jason.encode!(statements))}
        end
      ]
    }
  end

  test "query error carries the failing statement's index" do
    client =
      client_with_response([
        %{"status" => "OK", "result" => []},
        %{"status" => "ERR", "result" => "boom"}
      ])

    assert {:error, %SurrealDB.Error{type: :surreal_error, details: %{statement_index: 1}}} =
             SurrealDB.query(client, "RETURN 1; RETURN 2;")
  end

  test "generic rollback entries lose to the statement that actually failed" do
    client =
      client_with_response([
        %{"status" => "OK", "result" => nil},
        %{"status" => "ERR", "result" => @failed},
        %{"status" => "ERR", "result" => "Database record `person:dup` already exists"},
        %{"status" => "ERR", "result" => @cancelled},
        %{"status" => "ERR", "result" => @commit_aborted}
      ])

    assert {:error, %SurrealDB.Error{message: message, details: %{statement_index: 2}}} =
             SurrealDB.query(client, "BEGIN TRANSACTION; RETURN 1; COMMIT TRANSACTION;")

    assert message =~ "already exists"
  end

  test "all-generic entries fall back to the first ERR entry" do
    client =
      client_with_response([
        %{"status" => "ERR", "result" => @failed},
        %{"status" => "ERR", "result" => @cancelled},
        %{"status" => "ERR", "result" => @commit_aborted}
      ])

    assert {:error, %SurrealDB.Error{details: %{statement_index: 0}}} =
             SurrealDB.query(client, "BEGIN TRANSACTION; RETURN 1; COMMIT TRANSACTION;")
  end
end
