defmodule SurrealDB.ErrorTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Error

  test "not_started/1 builds a typed error" do
    error = Error.not_started(MyApp.Store)
    assert %Error{type: :not_started, details: %{store: MyApp.Store}} = error
    assert error.message =~ "not started"
  end

  test "not_connected/1 builds a typed error" do
    error = Error.not_connected(MyApp.Store)
    assert %Error{type: :not_connected, details: %{store: MyApp.Store}} = error
    assert error.message =~ "not connected"
  end
end
