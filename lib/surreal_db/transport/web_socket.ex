defmodule SurrealDB.Transport.WebSocket do
  @moduledoc false

  @behaviour SurrealDB.Transport

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.RPC.Request
  alias SurrealDB.RPC.Response
  alias SurrealDB.WebSocket.Connection

  @impl true
  def call(%Client{connection: pid} = _client, %Request{} = request) when is_pid(pid) do
    Connection.call(pid, request)
  end

  def call(%Client{}, %Request{}) do
    {:error,
     %Error{type: :websocket_connect_error, message: "websocket connection is not initialized"}}
  end

  @spec call(Client.t(), Request.t(), timeout()) :: {:ok, Response.t()} | {:error, Error.t()}
  def call(%Client{connection: pid} = _client, %Request{} = request, timeout) when is_pid(pid) do
    Connection.call(pid, request, timeout)
  end
end
