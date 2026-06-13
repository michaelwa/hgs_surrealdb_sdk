defmodule SurrealDB.Repo.FilterBuilderTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Error
  alias SurrealDB.Repo.FilterBuilder

  test "empty filters produce no clause" do
    assert {:ok, {"", %{}}} = FilterBuilder.build(%{})
  end

  test "single equality filter is parameterized" do
    assert {:ok, {"WHERE email = $email", %{email: "jane@example.com"}}} =
             FilterBuilder.build(%{email: "jane@example.com"})
  end

  test "multiple filters are alphabetized and AND-joined" do
    assert {:ok, {"WHERE email = $email AND status = $status", vars}} =
             FilterBuilder.build(%{status: "active", email: "jane@example.com"})

    assert vars == %{email: "jane@example.com", status: "active"}
  end

  test "string keys are accepted and preserved in vars" do
    assert {:ok, {"WHERE email = $email", %{"email" => "x"}}} =
             FilterBuilder.build(%{"email" => "x"})
  end

  test "invalid field names are rejected, not interpolated" do
    assert {:error, %Error{type: :invalid_filter}} = FilterBuilder.build(%{"name; DROP" => 1})
  end
end
