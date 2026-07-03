defmodule SurrealDB.Store.TransactionTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Multi

  defmodule UnstartedStore do
    use SurrealDB.Store, otp_app: :hgs_surrealdb_sdk
  end

  test "transaction/1 on a store that is not started returns a :transaction error" do
    assert {:error, :transaction, %SurrealDB.Error{type: :not_started}} =
             UnstartedStore.transaction(Multi.new())
  end
end
