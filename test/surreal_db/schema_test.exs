defmodule SurrealDB.SchemaTest do
  use ExUnit.Case, async: true

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

  test "__table__/0 returns the declared table" do
    assert User.__table__() == "user"
  end

  test "the schema module defines a struct with the declared fields" do
    user = %User{}
    assert Map.keys(Map.from_struct(user)) |> Enum.sort() == [:age, :email, :id, :name]
  end

  test "validate/1 returns the validated map for valid params" do
    assert {:ok, %{name: "Jane", email: "jane@example.com"}} =
             User.validate(%{name: "Jane", email: "jane@example.com"})
  end

  test "validate/1 returns a ValidationError for invalid params" do
    assert {:error, %ValidationError{errors: errors}} = User.validate(%{name: "Jane"})
    assert Enum.any?(errors, fn %{path: path} -> path == [:email] end)
  end

  test "hydrate/1 builds a struct from a DB record with string keys" do
    record = %{"id" => "user:abc", "name" => "Jane", "email" => "jane@example.com"}
    assert {:ok, %User{id: "user:abc", name: "Jane", email: "jane@example.com"}} =
             User.hydrate(record)
  end

  test "hydrate/1 returns a ValidationError for an invalid record" do
    assert {:error, %ValidationError{}} = User.hydrate(%{"name" => "Jane"})
  end

  test "dump/1 turns a struct into a validated map, dropping nils" do
    user = %User{name: "Jane", email: "jane@example.com"}
    assert {:ok, dumped} = User.dump(user)
    assert dumped == %{name: "Jane", email: "jane@example.com"}
  end
end
