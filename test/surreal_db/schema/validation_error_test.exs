defmodule SurrealDB.Schema.ValidationErrorTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Schema.ValidationError

  test "from_zoi/1 normalizes a list of errors into plain maps" do
    error =
      ValidationError.from_zoi([
        %{path: [:email], message: "invalid email format"},
        %{path: [:age], message: "too small: must be at least 0"}
      ])

    assert %ValidationError{errors: errors} = error

    assert errors == [
             %{path: [:email], message: "invalid email format"},
             %{path: [:age], message: "too small: must be at least 0"}
           ]
  end

  test "from_zoi/1 builds a readable summary message" do
    error = ValidationError.from_zoi([%{path: [:email], message: "invalid email format"}])

    assert error.message =~ "email"
    assert error.message =~ "invalid email format"
  end

  test "from_zoi/1 handles an empty path as root" do
    error = ValidationError.from_zoi([%{path: [], message: "is invalid"}])

    assert error.errors == [%{path: [], message: "is invalid"}]
    assert error.message =~ "is invalid"
  end

  test "is a raisable exception" do
    error = ValidationError.from_zoi([%{path: [:name], message: "is required"}])
    assert is_binary(Exception.message(error))
  end
end
