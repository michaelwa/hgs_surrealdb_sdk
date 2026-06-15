defmodule SurrealDB.Store.Supervisor do
  @moduledoc false

  use Supervisor

  alias SurrealDB.Client
  alias SurrealDB.Config
  alias SurrealDB.Error
  alias SurrealDB.Store.Server
  alias SurrealDB.WebSocket.Connection

  @spec start_link(module(), atom(), keyword()) ::
          {:ok, pid()} | {:error, SurrealDB.Error.t() | term()}
  def start_link(store, otp_app, opts)
      when is_atom(store) and is_atom(otp_app) and is_list(opts) do
    resolved = resolve_config(otp_app, store, opts)

    with {:ok, %Client{} = client} <- Config.build_client(resolved),
         {:ok, pid} <-
           Supervisor.start_link(__MODULE__, {store, client, resolved},
             name: supervisor_name(store)
           ) do
      {:ok, pid}
    else
      {:error, {:already_started, _pid}} ->
        {:error,
         Error.invalid_config("store #{inspect(store)} is already started", %{store: store})}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def init({store, %Client{} = client, resolved}) do
    children = [{Server, {store, client}}] ++ connection_children(store, client, resolved)
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp connection_children(store, %Client{transport: :websocket} = client, resolved) do
    via = {:via, Registry, {SurrealDB.Store.Registry, store}}

    # A supervised Store always self-heals: :name (the registry via-tuple) and
    # :reconnect are forced here. For a one-shot, non-reconnecting WS connection,
    # use SurrealDB.connect_ws/1 directly instead of a Store.
    connection_opts =
      resolved
      |> Keyword.get(:websocket_options, [])
      |> Keyword.put(:name, via)
      |> Keyword.put(:reconnect, true)

    [
      %{
        id: Connection,
        start: {Connection, :start_link, [client, connection_opts]},
        restart: :permanent
      }
    ]
  end

  defp connection_children(_store, %Client{}, _resolved), do: []

  defp resolve_config(otp_app, store, opts) do
    otp_app
    |> Application.get_env(store, [])
    |> Keyword.merge(opts)
  end

  defp supervisor_name(store), do: Module.concat(store, "Supervisor")
end
