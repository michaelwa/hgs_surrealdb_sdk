defmodule SurrealDB.WebSocket do
  @moduledoc false

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.WebSocket.Connection

  @spec connect(Client.t(), keyword()) :: {:ok, Client.t()} | {:error, Error.t()}
  def connect(%Client{} = client, options \\ []) do
    case Connection.start_link(client, options) do
      {:ok, pid} ->
        Process.unlink(pid)

        case Connection.await_ready(pid, Keyword.get(options, :timeout, 5_000)) do
          :ok ->
            {:ok, %Client{client | transport: :websocket, connection: pid}}

          {:error, %Error{} = error} ->
            stop_connection(pid)
            {:error, error}
        end

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

  defp stop_connection(pid) do
    if Process.alive?(pid) do
      try do
        Connection.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end
end
