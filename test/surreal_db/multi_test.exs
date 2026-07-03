defmodule SurrealDB.MultiTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Multi

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
end
