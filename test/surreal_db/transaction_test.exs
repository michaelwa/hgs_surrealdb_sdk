defmodule SurrealDB.TransactionTest do
  use ExUnit.Case, async: true

  alias SurrealDB.{Client, Multi}
  alias SurrealDB.Schema.ValidationError

  defmodule User do
    use SurrealDB.Schema

    table("user")

    schema do
      Zoi.object(%{
        id: Zoi.string() |> Zoi.optional(),
        name: Zoi.string(),
        email: Zoi.string()
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

  defp response(statements) do
    fn request ->
      {request, Req.Response.new(status: 200, body: Jason.encode!(statements))}
    end
  end

  @jane %{"id" => "user:1", "name" => "Jane", "email" => "jane@example.com"}
  @failed "The query was not executed due to a failed transaction"
  @cancelled "The query was not executed due to a cancelled transaction"
  @commit_aborted "Cannot COMMIT: the transaction was aborted due to a prior error"

  test "empty multi returns {:ok, %{}} without touching the network" do
    client = client_with_adapter(fn _request -> raise "network must not be called" end)

    assert {:ok, %{}} = SurrealDB.transaction(client, Multi.new())
  end

  test "success maps the RETURN payload to step names and hydrates schema steps" do
    returned = %{"user" => [@jane], "count" => 1}

    client =
      client_with_adapter(
        response([
          %{"status" => "OK", "result" => nil},
          %{"status" => "OK", "result" => nil},
          %{"status" => "OK", "result" => nil},
          %{"status" => "OK", "result" => returned},
          %{"status" => "OK", "result" => nil}
        ])
      )

    multi =
      Multi.new()
      |> Multi.create(:user, User, %{name: "Jane", email: "jane@example.com"})
      |> Multi.raw(:count, "SELECT count() FROM user GROUP ALL")

    assert {:ok, %{user: %User{id: "user:1", name: "Jane"}, count: 1}} =
             SurrealDB.transaction(client, multi)
  end

  test "validation failure aborts before any network call" do
    client = client_with_adapter(fn _request -> raise "network must not be called" end)

    multi = Multi.new() |> Multi.create(:user, User, %{name: "Jane"})

    assert {:error, :user, %ValidationError{}} = SurrealDB.transaction(client, multi)
  end

  test "server rollback attributes the error to the failing step" do
    client =
      client_with_adapter(
        response([
          %{"status" => "OK", "result" => nil},
          %{"status" => "ERR", "result" => @failed},
          %{"status" => "ERR", "result" => "Database record `user:dup` already exists"},
          %{"status" => "ERR", "result" => @cancelled},
          %{"status" => "ERR", "result" => @commit_aborted}
        ])
      )

    multi =
      Multi.new()
      |> Multi.create(:a, User, %{name: "A", email: "a@example.com"})
      |> Multi.raw(:b, "CREATE user:dup")

    assert {:error, :b, %SurrealDB.Error{type: :surreal_error}} =
             SurrealDB.transaction(client, multi)
  end

  test "transport failure attributes to :transaction" do
    client =
      client_with_adapter(fn request ->
        {request, Req.Response.new(status: 500, body: "boom")}
      end)

    multi = Multi.new() |> Multi.create(:user, User, %{name: "J", email: "j@example.com"})

    assert {:error, :transaction, %SurrealDB.Error{}} = SurrealDB.transaction(client, multi)
  end

  test "hydration failure after commit surfaces the step and a ValidationError" do
    returned = %{"user" => [%{"id" => "user:1"}]}

    client =
      client_with_adapter(
        response([
          %{"status" => "OK", "result" => nil},
          %{"status" => "OK", "result" => nil},
          %{"status" => "OK", "result" => returned},
          %{"status" => "OK", "result" => nil}
        ])
      )

    multi =
      Multi.new() |> Multi.create(:user, User, %{name: "Jane", email: "jane@example.com"})

    assert {:error, :user, %ValidationError{}} = SurrealDB.transaction(client, multi)
  end
end
