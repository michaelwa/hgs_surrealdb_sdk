defmodule SurrealDB.WebSocket do
  @moduledoc false

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.WebSocket.Connection

  @spec connect(Client.t(), keyword()) :: {:ok, Client.t()} | {:error, Error.t()}
  def connect(%Client{} = client, options \\ []) do
    with {:ok, pid} <- Connection.start_link(client, options) do
      {:ok, %Client{client | transport: :websocket, connection: pid}}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, %Error{type: :websocket_connect_error, message: inspect(reason), raw: reason}}
    end
  end

  @spec stop(Client.t()) :: :ok | {:error, Error.t()}
  def stop(%Client{connection: pid}) when is_pid(pid) do
    Connection.stop(pid)
  end

  def stop(_client), do: :ok
end
