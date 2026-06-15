defmodule HgsSurrealdbSdk.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: SurrealDB.Store.Registry}
    ]

    opts = [strategy: :one_for_one, name: HgsSurrealdbSdk.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
