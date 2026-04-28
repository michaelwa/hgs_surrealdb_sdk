defmodule SurrealDB.Transport.HTTP do
  @moduledoc false

  @behaviour SurrealDB.Transport

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.RPC.Request
  alias SurrealDB.RPC.Response
  alias SurrealDB.Variables

  @impl true
  def call(%Client{} = client, %Request{} = rpc_request) do
    with {:ok, req_body} <- build_rpc_body(rpc_request),
         {:ok, response} <- Req.request(http_request(client, req_body)),
         {:ok, decoded} <- decode_body(response.body),
         :ok <- ensure_http_success(response.status, decoded) do
      {:ok, build_rpc_response(rpc_request, decoded)}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, transport_error(reason)}
    end
  end

  defp build_rpc_body(%Request{method: "query", params: [query]}) when is_binary(query) do
    {:ok, query}
  end

  defp build_rpc_body(%Request{method: "query", params: [query, variables]})
       when is_binary(query) and is_map(variables) do
    Variables.apply(query, variables)
  end

  defp build_rpc_body(%Request{method: method, params: params}) do
    {:error,
     %Error{
       type: :rpc_error,
       message: "unsupported RPC method or params",
       details: %{method: method, params: params}
     }}
  end

  defp http_request(%Client{} = client, body) do
    [
      method: :post,
      url: client.endpoint <> "/sql",
      headers: headers(client),
      body: body
    ] ++ client.request_options
  end

  defp headers(%Client{} = client) do
    base_headers = [
      {"accept", "application/json"},
      {"content-type", "text/plain"},
      {"surreal-ns", client.namespace},
      {"surreal-db", client.database},
      {"ns", client.namespace},
      {"db", client.database}
    ]

    case client.auth do
      {:basic, %{username: username, password: password}} ->
        [{"authorization", "Basic " <> Base.encode64("#{username}:#{password}")} | base_headers]

      {:bearer, token} ->
        [{"authorization", "Bearer " <> token} | base_headers]

      nil ->
        base_headers
    end
  end

  defp decode_body(body) when is_list(body), do: {:ok, body}
  defp decode_body(body) when is_map(body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, rpc_decode_error(body, reason)}
    end
  end

  defp decode_body(body), do: {:ok, body}

  defp ensure_http_success(status, _decoded) when status in 200..299, do: :ok
  defp ensure_http_success(status, decoded), do: {:error, transport_status_error(status, decoded)}

  defp build_rpc_response(%Request{id: id}, %{"error" => error} = raw) when is_map(error) do
    Response.failure(id, error, raw)
  end

  defp build_rpc_response(%Request{id: id}, raw) do
    Response.success(id, raw, raw)
  end

  defp rpc_decode_error(body, reason) do
    %Error{
      type: :rpc_decode_error,
      message: "failed to decode RPC response",
      details: %{body: body, reason: inspect(reason)},
      raw: reason
    }
  end

  defp transport_status_error(status, body) do
    %Error{
      type: :transport_error,
      status: status,
      message: "transport request failed with status #{status}",
      details: %{body: body},
      raw: body
    }
  end

  defp transport_error(%{message: message} = error) when is_binary(message) do
    %Error{
      type: :transport_error,
      message: message,
      details: %{exception: error.__struct__},
      raw: error
    }
  end

  defp transport_error(error) do
    %Error{type: :transport_error, message: "transport request failed", raw: error}
  end
end
