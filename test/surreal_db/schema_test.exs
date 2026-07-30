defmodule SurrealDB.SchemaTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Schema.ValidationError

  defmodule User do
    use SurrealDB.Schema

    table("user")

    schema do
      Zoi.object(%{
        id: Zoi.string() |> Zoi.optional(),
        name: Zoi.string(),
        email: Zoi.string(),
        age: Zoi.integer() |> Zoi.optional()
      })
    end
  end

  defmodule UserWithProfile do
    use SurrealDB.Schema

    table("user")

    schema do
      Zoi.object(%{
        id: Zoi.string() |> Zoi.optional(),
        name: Zoi.string(),
        profile: Zoi.object(%{age: Zoi.integer()})
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

  test "validate_partial/1 accepts a subset of declared fields" do
    assert {:ok, %{age: 37}} = User.validate_partial(%{age: 37})
  end

  test "validate_partial/1 coerces supplied values with the field schema" do
    assert {:ok, %{age: 37}} = User.validate_partial(%{age: "37"})
  end

  test "validate_partial/1 rejects an invalid supplied value" do
    assert {:error, %ValidationError{}} = User.validate_partial(%{age: "not an integer"})
  end

  test "validate_partial/1 rejects unknown fields" do
    assert {:error, %ValidationError{errors: errors}} =
             User.validate_partial(%{nickname: "J"})

    assert Enum.any?(errors, fn %{path: path} -> path == [] or path == [:nickname] end)
  end

  test "validate_partial/1 validates supplied nested values" do
    assert {:error, %ValidationError{}} =
             UserWithProfile.validate_partial(%{profile: %{age: "not an integer"}})
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

  test "dump/1 returns a ValidationError for a non-struct argument" do
    assert {:error, %ValidationError{}} = User.dump(%{name: "Jane"})
  end
end
