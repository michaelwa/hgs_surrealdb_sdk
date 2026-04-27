defmodule SurrealDB.RPC do
  @moduledoc false

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.RPC.Request
  alias SurrealDB.RPC.Response
  alias SurrealDB.Transport.HTTP
  alias SurrealDB.Transport.WebSocket

  @spec call(Client.t(), String.t(), list()) :: {:ok, Response.t()} | {:error, Error.t()}
  def call(%Client{} = client, method, params \\ []) when is_binary(method) and is_list(params) do
    request = Request.new(method, params)

    with {:ok, %Response{} = response} <- transport(client).call(client, request) do
      case response.error do
        nil -> {:ok, response}
        _ -> {:error, Response.to_error(response)}
      end
    end
  end

  defp transport(%Client{transport: :websocket}), do: WebSocket
  defp transport(%Client{}), do: HTTP
end
