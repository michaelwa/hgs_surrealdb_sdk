defmodule SurrealDB.Store.ServerTest do
  use ExUnit.Case, async: false

  alias SurrealDB.Client
  alias SurrealDB.Store.Server

  defmodule FakeStore do
  end

  setup do
    on_exit(fn -> :persistent_term.erase({SurrealDB.Store, FakeStore}) end)
    :ok
  end

  test "publishes the client to persistent_term on start and erases on stop" do
    client = %Client{endpoint: "http://localhost:8000", namespace: "ns", database: "db"}

    {:ok, pid} = Server.start_link({FakeStore, client})

    assert :persistent_term.get({SurrealDB.Store, FakeStore}) == client

    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    assert :persistent_term.get({SurrealDB.Store, FakeStore}, :missing) == :missing
  end
end
