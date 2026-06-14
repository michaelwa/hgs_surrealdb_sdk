defmodule SurrealDB.Store.SupervisorTest do
  use ExUnit.Case, async: false

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.Store.Supervisor, as: StoreSupervisor

  defmodule HttpStore do
  end

  setup do
    on_exit(fn ->
      case Process.whereis(Module.concat(HttpStore, "Supervisor")) do
        nil -> :ok
        pid -> catch_exit(Supervisor.stop(pid))
      end

      Application.delete_env(:store_sup_test, HttpStore)
      :persistent_term.erase({SurrealDB.Store, HttpStore})
    end)

    :ok
  end

  test "resolves app env, publishes a validated client, starts supervised" do
    Application.put_env(:store_sup_test, HttpStore,
      endpoint: "http://localhost:8000",
      namespace: "ns",
      database: "db",
      username: "root",
      password: "root"
    )

    assert {:ok, pid} = StoreSupervisor.start_link(HttpStore, :store_sup_test, [])
    assert is_pid(pid)

    client = :persistent_term.get({SurrealDB.Store, HttpStore})
    assert %Client{endpoint: "http://localhost:8000", namespace: "ns", transport: :http} = client
  end

  test "inline opts override app env" do
    Application.put_env(:store_sup_test, HttpStore,
      endpoint: "http://localhost:8000",
      namespace: "ns",
      database: "db",
      username: "root",
      password: "root"
    )

    assert {:ok, _pid} =
             StoreSupervisor.start_link(HttpStore, :store_sup_test, namespace: "override")

    assert %Client{namespace: "override"} = :persistent_term.get({SurrealDB.Store, HttpStore})
  end

  test "invalid config returns a structured error and does not start" do
    Application.put_env(:store_sup_test, HttpStore, endpoint: "http://localhost:8000")

    assert {:error, %Error{type: :invalid_config}} =
             StoreSupervisor.start_link(HttpStore, :store_sup_test, [])

    assert :persistent_term.get({SurrealDB.Store, HttpStore}, :missing) == :missing
  end

  test "starting the same store twice returns a structured already-started error" do
    Application.put_env(:store_sup_test, HttpStore,
      endpoint: "http://localhost:8000",
      namespace: "ns",
      database: "db",
      username: "root",
      password: "root"
    )

    assert {:ok, _pid} = StoreSupervisor.start_link(HttpStore, :store_sup_test, [])

    assert {:error, %Error{type: :invalid_config}} =
             StoreSupervisor.start_link(HttpStore, :store_sup_test, [])
  end
end
