defmodule SurrealDB.RPC do
  @moduledoc false

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.RPC.Request
  alias SurrealDB.RPC.Response
  alias SurrealDB.Telemetry
  alias SurrealDB.Transport.HTTP
  alias SurrealDB.Transport.WebSocket

  @spec call(Client.t(), String.t(), list()) :: {:ok, Response.t()} | {:error, Error.t()}
  def call(%Client{} = client, method, params \\ []) when is_binary(method) and is_list(params) do
    Telemetry.span(client, method, telemetry_fields(method, params), fn ->
      do_call(client, method, params)
    end)
  end

  defp do_call(%Client{} = client, method, params) do
    request = Request.new(method, params)

    with {:ok, %Response{} = response} <- transport(client).call(client, request) do
      case response.error do
        nil -> {:ok, response}
        _ -> {:error, Response.to_error(response)}
      end
    end
  end

  defp telemetry_fields("query", [query]), do: [query: query]
  defp telemetry_fields("query", [query, variables]), do: [query: query, variables: variables]
  defp telemetry_fields(_method, params), do: [params: params]

  defp transport(%Client{transport: :websocket}), do: WebSocket
  defp transport(%Client{}), do: HTTP
end
