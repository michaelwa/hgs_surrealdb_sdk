defmodule SurrealDB.HTTP do
  @moduledoc false

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.QueryResult

  @spec query(Client.t(), String.t()) :: {:ok, QueryResult.t()} | {:error, Error.t()}
  def query(%Client{} = client, query) when is_binary(query) do
    request =
      [
        method: :post,
        url: client.endpoint <> "/sql",
        headers: headers(client),
        body: query
      ] ++ client.request_options

    do_query(request)
  rescue
    error in RuntimeError ->
      {:error, Error.request(error)}
  end

  defp do_query(request) do
    with {:ok, response} <- Req.request(request),
         {:ok, body} <- decode_body(response.body),
         :ok <- ensure_success(response.status, body),
         {:ok, result} <- QueryResult.from_response(body) do
      {:ok, result}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.request(reason)}
    end
  end

  defp headers(%Client{} = client) do
    base_headers = [
      {"accept", "application/json"},
      {"content-type", "text/plain"},
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
      {:error, reason} -> {:error, Error.decode_failure(body, reason)}
    end
  end

  defp decode_body(body), do: {:ok, body}

  defp ensure_success(status, body) when status in 200..299 do
    case extract_statement_error(body) do
      nil -> :ok
      statement -> {:error, Error.surreal_failure(statement)}
    end
  end

  defp ensure_success(status, body), do: {:error, Error.http_failure(status, body)}

  defp extract_statement_error(body) when is_list(body) do
    Enum.find(body, &(Map.get(&1, "status") == "ERR"))
  end

  defp extract_statement_error(_body), do: nil
end
