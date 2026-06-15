defmodule HgsSurrealdbSdk.ApplicationTest do
  use ExUnit.Case, async: true

  test "the store registry is started and empty by default" do
    assert is_pid(Process.whereis(SurrealDB.Store.Registry))
    assert Registry.lookup(SurrealDB.Store.Registry, :missing_store) == []
  end
end
