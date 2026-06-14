defmodule SurrealDB.Store.Supervisor do
  @moduledoc false

  use Supervisor

  alias SurrealDB.Client
  alias SurrealDB.Config
  alias SurrealDB.Store.Server

  @spec start_link(module(), atom(), keyword()) ::
          {:ok, pid()} | {:error, SurrealDB.Error.t() | term()}
  def start_link(store, otp_app, opts) when is_atom(store) and is_atom(otp_app) do
    resolved = resolve_config(otp_app, store, opts)

    with {:ok, %Client{} = client} <- Config.build_client(resolved) do
      Supervisor.start_link(__MODULE__, {store, client, resolved}, name: supervisor_name(store))
    end
  end

  @impl true
  def init({store, %Client{} = client, _resolved}) do
    children = [
      {Server, {store, client}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp resolve_config(otp_app, store, opts) do
    otp_app
    |> Application.get_env(store, [])
    |> Keyword.merge(opts)
  end

  defp supervisor_name(store), do: Module.concat(store, "Supervisor")
end
