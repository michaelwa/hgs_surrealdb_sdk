defmodule SurrealDB.MultiTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Multi
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

  defmodule Account do
    use SurrealDB.Schema

    table("account")

    schema do
      Zoi.object(%{
        id: Zoi.string() |> Zoi.optional(),
        owner: Zoi.string() |> Zoi.optional(),
        balance: Zoi.integer()
      })
    end
  end

  test "new/0 starts with no ops" do
    assert %Multi{ops: []} = Multi.new()
  end

  test "steps accumulate in pipeline order with their kinds" do
    multi =
      Multi.new()
      |> Multi.create(:user, User, %{name: "Jane", email: "jane@example.com"})
      |> Multi.update(:acct, Account, "account:abc", %{balance: 250})
      |> Multi.delete(:old, User, "user:old")
      |> Multi.let(:owner, "SELECT * FROM $user.id")
      |> Multi.raw(:rel, "RELATE $owner->owns->$acct")

    assert Enum.map(multi.ops, &{&1.name, &1.kind}) == [
             {:user, :create},
             {:acct, :update},
             {:old, :delete},
             {:owner, :let},
             {:rel, :raw}
           ]
  end

  test "duplicate step names raise ArgumentError" do
    assert_raise ArgumentError, ~r/already in this multi/, fn ->
      Multi.new()
      |> Multi.raw(:a, "RETURN 1")
      |> Multi.raw(:a, "RETURN 2")
    end
  end

  test "step names must be valid identifiers" do
    assert_raise ArgumentError, ~r/valid identifier/, fn ->
      Multi.new() |> Multi.raw(:"bad name", "RETURN 1")
    end
  end

  test "to_query/1 assembles a BEGIN/LET/RETURN/COMMIT block with namespaced vars" do
    {:ok, surql, vars} =
      Multi.new()
      |> Multi.create(:user, User, %{name: "Jane", email: "jane@example.com"})
      |> Multi.update(:acct, Account, "account:abc", %{balance: 250})
      |> Multi.let(:owner, "SELECT * FROM $user.id")
      |> Multi.raw(:rel, "RELATE $owner->owns->$acct")
      |> Multi.to_query()

    assert String.split(surql, "\n") == [
             "BEGIN TRANSACTION;",
             "LET $user = (CREATE type::table($s0___table__) CONTENT $s0_attrs);",
             "LET $acct = (UPDATE account:abc MERGE $s1_attrs);",
             "LET $owner = (SELECT * FROM $user.id);",
             "LET $rel = (RELATE $owner->owns->$acct);",
             "RETURN { user: $user, acct: $acct, owner: $owner, rel: $rel };",
             "COMMIT TRANSACTION;"
           ]

    assert vars["s0___table__"] == "user"

    assert Jason.decode!(Jason.encode!(vars["s0_attrs"])) ==
             %{"name" => "Jane", "email" => "jane@example.com"}

    assert Jason.decode!(Jason.encode!(vars["s1_attrs"])) == %{"balance" => 250}
    assert map_size(vars) == 3
  end

  test "to_query/1 namespaces let/raw vars but leaves step references alone" do
    {:ok, surql, vars} =
      Multi.new()
      |> Multi.raw(:adults, "SELECT * FROM person WHERE age > $min", %{min: 21})
      |> Multi.to_query()

    assert surql =~ "LET $adults = (SELECT * FROM person WHERE age > $s0_min);"
    assert vars == %{"s0_min" => 21}
  end

  test "to_query/1 short-circuits on the first invalid step with its name" do
    assert {:error, :bad_user, %ValidationError{}} =
             Multi.new()
             |> Multi.create(:ok_user, User, %{name: "Jane", email: "jane@example.com"})
             |> Multi.create(:bad_user, User, %{name: "NoEmail"})
             |> Multi.to_query()
  end

  test "to_query/1 rejects an invalid update id with the step name" do
    assert {:error, :acct, %SurrealDB.Error{type: :invalid_identifier}} =
             Multi.new()
             |> Multi.update(:acct, Account, "account; DROP", %{balance: 1})
             |> Multi.to_query()
  end
end
