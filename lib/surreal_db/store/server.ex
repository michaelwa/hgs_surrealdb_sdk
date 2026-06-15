defmodule SurrealDB.Store.Server do
  @moduledoc false

  use GenServer

  alias SurrealDB.Client

  @spec start_link({module(), Client.t()}) :: GenServer.on_start()
  def start_link({store, %Client{} = client}) when is_atom(store) do
    GenServer.start_link(__MODULE__, {store, client})
  end

  @impl true
  def init({store, %Client{} = client}) do
    :persistent_term.put({SurrealDB.Store, store}, client)
    Process.flag(:trap_exit, true)
    {:ok, %{store: store}}
  end

  @impl true
  def terminate(_reason, %{store: store}) do
    :persistent_term.erase({SurrealDB.Store, store})
    :ok
  end
end
