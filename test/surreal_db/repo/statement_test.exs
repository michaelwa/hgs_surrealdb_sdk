defmodule SurrealDB.Repo.StatementTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Repo.Statement
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

  test "create/2 validates attrs and builds CREATE with nil-stripped content" do
    assert {:ok, {surql, vars}} =
             Statement.create(User, %{name: "Jane", email: "jane@example.com"})

    assert surql == "CREATE type::table($__table__) CONTENT $attrs"
    assert vars[:__table__] == "user"

    assert Jason.decode!(Jason.encode!(vars[:attrs])) ==
             %{"name" => "Jane", "email" => "jane@example.com"}
  end

  test "create/2 surfaces Zoi validation errors" do
    assert {:error, %ValidationError{}} = Statement.create(User, %{name: "Jane"})
  end

  test "update/3 builds UPDATE MERGE and validates the record id" do
    assert {:ok, {"UPDATE user:abc MERGE $attrs", %{attrs: %{name: "X"}}}} =
             Statement.update(User, "user:abc", %{name: "X"})

    assert {:error, %SurrealDB.Error{type: :invalid_identifier}} =
             Statement.update(User, "user; DROP", %{name: "X"})
  end

  test "update/3 validates and returns coerced attributes" do
    assert {:ok, {"UPDATE user:abc MERGE $attrs", %{attrs: %{email: "jane@example.com"}}}} =
             Statement.update(User, "user:abc", %{email: "jane@example.com"})
  end

  test "update/3 rejects invalid values before building a statement" do
    assert {:error, %ValidationError{}} =
             Statement.update(User, "user:abc", %{age: "not an integer"})
  end

  test "update/3 rejects unknown fields before building a statement" do
    assert {:error, %ValidationError{}} =
             Statement.update(User, "user:abc", %{nickname: "J"})
  end

  test "delete/2 builds DELETE RETURN BEFORE and validates the record id" do
    assert {:ok, {"DELETE user:abc RETURN BEFORE", %{}}} = Statement.delete(User, "user:abc")

    assert {:error, %SurrealDB.Error{type: :invalid_identifier}} =
             Statement.delete(User, "user; DROP")
  end
end
