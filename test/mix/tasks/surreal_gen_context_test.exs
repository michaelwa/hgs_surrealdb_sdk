defmodule Mix.Tasks.Surreal.Gen.ContextTest do
  use ExUnit.Case, async: true
  import Igniter.Test

  test "generates the Zoi schema module" do
    test_project()
    |> Igniter.compose_task("surreal.gen.context", [
      "Accounts",
      "User",
      "name:string",
      "email:string",
      "age:int?"
    ])
    |> assert_creates("lib/test/accounts/user.ex")
  end

  test "generates the context module with delegating CRUD" do
    test_project()
    |> Igniter.compose_task("surreal.gen.context", ["Accounts", "User", "name:string"])
    |> assert_creates("lib/test/accounts.ex", """
    defmodule Test.Accounts do
      @moduledoc \"\"\"
      The Accounts context.
      \"\"\"
      alias Test.Accounts.User
      alias Test.SurrealStore

      def list_users(filters \\\\ %{}), do: SurrealStore.all(User, filters)
      def get_user(id), do: SurrealStore.get(User, id)
      def create_user(attrs), do: SurrealStore.create(User, attrs)
      def update_user(id, attrs), do: SurrealStore.update(User, id, attrs)
      def delete_user(id), do: SurrealStore.delete(User, id)
    end
    """)
  end

  test "creates the migration at a deterministic path with --migration-timestamp" do
    test_project()
    |> Igniter.compose_task("surreal.gen.context", [
      "Accounts",
      "User",
      "name:string",
      "--migration-timestamp",
      "20260627000000"
    ])
    |> assert_creates(
      "priv/surreal_repo/migrations/20260627000000_create_user.surql",
      """
      -- create_user

      -- migrate:up
      DEFINE TABLE user TYPE NORMAL SCHEMAFULL PERMISSIONS NONE;
      DEFINE FIELD name ON user TYPE STRING;

      -- migrate:down
      REMOVE TABLE user;
      """
    )
  end

  test "honors --table and --store overrides" do
    test_project()
    |> Igniter.compose_task("surreal.gen.context", [
      "Accounts",
      "Person",
      "name:string",
      "--table",
      "people_record",
      "--store",
      "Test.OtherStore",
      "--migration-timestamp",
      "20260627000000"
    ])
    |> assert_creates("priv/surreal_repo/migrations/20260627000000_create_people_record.surql")
  end
end
