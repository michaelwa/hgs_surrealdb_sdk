defmodule SurrealDB do
  @moduledoc """
  Public API for the minimal HTTP-based SurrealDB client.

  ## Example

      {:ok, client} =
        SurrealDB.connect(
          endpoint: "http://localhost:8000",
          namespace: "test",
          database: "test",
          username: "root",
          password: "root"
        )

      SurrealDB.query(client, "SELECT * FROM person")
  """

  alias SurrealDB.Client
  alias SurrealDB.Config
  alias SurrealDB.Error
  alias SurrealDB.Identifier
  alias SurrealDB.QueryResult
  alias SurrealDB.RPC
  alias SurrealDB.WebSocket

  @spec connect(keyword()) :: {:ok, Client.t()} | {:error, SurrealDB.Error.t()}
  def connect(options) when is_list(options) do
    Config.build_client(options)
  end

  @spec connect_ws(keyword()) :: {:ok, Client.t()} | {:error, Error.t()}
  def connect_ws(options) when is_list(options) do
    with {:ok, %Client{} = client} <-
           Config.build_client(Keyword.put(options, :transport, :websocket)),
         {:ok, %Client{} = ws_client} <-
           WebSocket.connect(client, Keyword.get(options, :websocket_options, [])) do
      {:ok, ws_client}
    end
  end

  @spec query(Client.t(), iodata()) ::
          {:ok, SurrealDB.QueryResult.t()} | {:error, SurrealDB.Error.t()}
  def query(%Client{} = client, query) when is_binary(query) or is_list(query) do
    query(client, query, %{})
  end

  @spec query(Client.t(), iodata(), map()) ::
          {:ok, SurrealDB.QueryResult.t()} | {:error, SurrealDB.Error.t()}
  def query(%Client{} = client, query, variables)
      when (is_binary(query) or is_list(query)) and is_map(variables) do
    with {:ok, response} <- RPC.call(client, "query", [IO.iodata_to_binary(query), variables]),
         :ok <- ensure_query_success(response.result),
         {:ok, result} <- QueryResult.from_response(response.result) do
      {:ok, result}
    else
      {:error, %Error{} = error} ->
        {:error, normalize_query_error(error)}
    end
  end

  @spec rpc(Client.t(), String.t(), list()) ::
          {:ok, SurrealDB.RPC.Response.t()} | {:error, SurrealDB.Error.t()}
  def rpc(%Client{} = client, method, params) when is_binary(method) and is_list(params) do
    RPC.call(client, method, params)
  end

  @spec select(Client.t(), String.t()) ::
          {:ok, SurrealDB.QueryResult.t()} | {:error, SurrealDB.Error.t()}
  def select(%Client{} = client, thing) do
    with {:ok, identifier} <- Identifier.validate(thing) do
      query(client, "SELECT * FROM #{identifier}")
    end
  end

  @spec create(Client.t(), String.t(), map()) ::
          {:ok, SurrealDB.QueryResult.t()} | {:error, SurrealDB.Error.t()}
  def create(%Client{} = client, thing, data) when is_map(data) do
    with {:ok, identifier} <- Identifier.validate(thing) do
      query(client, "CREATE #{identifier} CONTENT $data", %{data: data})
    end
  end

  @spec update(Client.t(), String.t(), map()) ::
          {:ok, SurrealDB.QueryResult.t()} | {:error, SurrealDB.Error.t()}
  def update(%Client{} = client, thing, data) when is_map(data) do
    with {:ok, identifier} <- Identifier.validate(thing) do
      query(client, "UPDATE #{identifier} CONTENT $data", %{data: data})
    end
  end

  @spec merge(Client.t(), String.t(), map()) ::
          {:ok, SurrealDB.QueryResult.t()} | {:error, SurrealDB.Error.t()}
  def merge(%Client{} = client, thing, data) when is_map(data) do
    with {:ok, identifier} <- Identifier.validate(thing) do
      query(client, "UPDATE #{identifier} MERGE $data", %{data: data})
    end
  end

  @spec patch(Client.t(), String.t(), list()) ::
          {:ok, SurrealDB.QueryResult.t()} | {:error, SurrealDB.Error.t()}
  def patch(%Client{} = client, thing, operations) when is_list(operations) do
    with {:ok, identifier} <- Identifier.validate(thing) do
      query(client, "UPDATE #{identifier} PATCH $patch", %{patch: operations})
    end
  end

  @spec delete(Client.t(), String.t()) ::
          {:ok, SurrealDB.QueryResult.t()} | {:error, SurrealDB.Error.t()}
  def delete(%Client{} = client, thing) do
    with {:ok, identifier} <- Identifier.validate(thing) do
      query(client, "DELETE #{identifier}")
    end
  end

  defp ensure_query_success(body) when is_list(body) do
    case Enum.find(body, &(Map.get(&1, "status") == "ERR")) do
      nil -> :ok
      statement -> {:error, Error.surreal_error(statement)}
    end
  end

  defp ensure_query_success(_body), do: :ok

  defp normalize_query_error(%Error{type: :transport_error, status: status, raw: raw})
       when is_integer(status) do
    Error.http_error(status, raw)
  end

  defp normalize_query_error(%Error{
         type: :transport_error,
         message: message,
         raw: raw,
         details: details
       }) do
    %Error{type: :http_error, message: message, details: details, raw: raw}
  end

  defp normalize_query_error(%Error{
         type: :rpc_decode_error,
         message: message,
         details: details,
         raw: raw
       }) do
    %Error{type: :decode_error, message: message, details: details, raw: raw}
  end

  defp normalize_query_error(error), do: error
end
