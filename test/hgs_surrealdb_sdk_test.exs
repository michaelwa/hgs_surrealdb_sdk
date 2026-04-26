defmodule HgsSurrealdbSdkTest do
  use ExUnit.Case
  doctest HgsSurrealdbSdk

  test "greets the world" do
    assert HgsSurrealdbSdk.hello() == :world
  end
end
