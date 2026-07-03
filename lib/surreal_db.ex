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
  alias SurrealDB.Live
  alias SurrealDB.Live.Subscription
  alias SurrealDB.Multi
  alias SurrealDB.QueryResult
  alias SurrealDB.RPC
  alias SurrealDB.WebSocket

  @spec connect() :: {:ok, Client.t()} | {:error, SurrealDB.Error.t()}
  def connect do
    Config.build_application_client()
  end

  @spec connect(keyword()) :: {:ok, Client.t()} | {:error, SurrealDB.Error.t()}
  def connect(options) when is_list(options) do
    Config.build_client(options)
  end

  @spec connect_ws() :: {:ok, Client.t()} | {:error, Error.t()}
  def connect_ws do
    connect_ws([])
  end

  @spec connect_ws(keyword()) :: {:ok, Client.t()} | {:error, Error.t()}
  def connect_ws(options) when is_list(options) do
    with {:ok, options} <- connection_options(options),
         {:ok, %Client{} = client} <-
           Config.build_client(Keyword.put(options, :transport, :websocket)),
         {:ok, %Client{} = ws_client} <-
           WebSocket.connect(client, Keyword.get(options, :websocket_options, [])) do
      {:ok, ws_client}
    end
  end

  defp connection_options([]), do: Config.application_options()
  defp connection_options(options), do: {:ok, options}

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

  @doc """
  Runs a `SurrealDB.Multi` as one atomic transaction.

  Assembles the multi into a `BEGIN ... RETURN ... COMMIT` block, validates
  every step client-side first, and maps the transaction's RETURN payload back
  to step names, hydrating schema-backed steps.

  Returns `{:ok, %{step_name => result}}` or `{:error, step_name, reason}`.
  The step slot is `:transaction` when the failure cannot be attributed to a
  single step. On any server-side failure, SurrealDB rolls back the whole
  block; there are never partial writes.

  Note: a hydration failure on the response means the transaction has
  committed, but the returned record did not match the schema.
  """
  @spec transaction(Client.t(), Multi.t()) ::
          {:ok, %{atom() => term()}} | {:error, atom(), term()}
  def transaction(%Client{}, %Multi{ops: []}), do: {:ok, %{}}

  def transaction(%Client{} = client, %Multi{} = multi) do
    with {:ok, surql, vars} <- Multi.to_query(multi),
         {:ok, %QueryResult{} = result} <- query(client, surql, vars) do
      map_transaction_success(multi, result)
    else
      {:error, name, reason} -> {:error, name, reason}
      {:error, %Error{} = error} -> {:error, attribute_step(multi, error), error}
    end
  end

  @spec rpc(Client.t(), String.t(), list()) ::
          {:ok, SurrealDB.RPC.Response.t()} | {:error, SurrealDB.Error.t()}
  def rpc(%Client{} = client, method, params) when is_binary(method) and is_list(params) do
    RPC.call(client, method, params)
  end

  @doc """
  Exports the target database as a SurrealQL dump.

  Uses SurrealDB's HTTP `/export` endpoint and returns the dump as a binary.
  """
  @spec export(Client.t()) :: {:ok, binary()} | {:error, SurrealDB.Error.t()}
  def export(%Client{} = client) do
    SurrealDB.Transport.HTTP.export(client)
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

  @spec live(Client.t(), String.t(), keyword()) :: {:ok, Subscription.t()} | {:error, Error.t()}
  def live(%Client{} = client, query, opts \\ []) when is_binary(query) and is_list(opts) do
    Live.start(client, query, opts)
  end

  @spec kill(Client.t(), Subscription.t()) :: :ok | {:error, Error.t()}
  def kill(%Client{} = client, %Subscription{} = subscription) do
    Live.kill(client, subscription)
  end

  defp map_transaction_success(%Multi{ops: ops}, %QueryResult{results: results, raw: raw}) do
    return_index = length(ops) + 1

    case Enum.at(results, return_index) do
      %{} = returned -> hydrate_steps(ops, returned)
      _other -> {:error, :transaction, Error.unexpected_response(raw)}
    end
  end

  defp hydrate_steps(ops, returned) do
    Enum.reduce_while(ops, {:ok, %{}}, fn op, {:ok, acc} ->
      value = Map.get(returned, Atom.to_string(op.name))

      case hydrate_step(op, value) do
        {:ok, hydrated} -> {:cont, {:ok, Map.put(acc, op.name, hydrated)}}
        {:error, reason} -> {:halt, {:error, op.name, reason}}
      end
    end)
  end

  defp hydrate_step(%{kind: kind, schema: schema}, value)
       when kind in [:create, :update, :delete] do
    case normalize_record(value) do
      nil -> {:ok, nil}
      record -> schema.hydrate(record)
    end
  end

  defp hydrate_step(_op, value), do: {:ok, value}

  defp normalize_record([record | _rest]), do: record
  defp normalize_record([]), do: nil
  defp normalize_record(%{} = record), do: record
  defp normalize_record(_other), do: nil

  defp attribute_step(%Multi{ops: ops}, %Error{
         type: :surreal_error,
         details: %{statement_index: index}
       })
       when is_integer(index) do
    step_index = index - 1

    if step_index >= 0 do
      case Enum.at(ops, step_index) do
        %{name: name} -> name
        nil -> :transaction
      end
    else
      :transaction
    end
  end

  defp attribute_step(_multi, _error), do: :transaction

  @generic_transaction_errors MapSet.new([
                                "The query was not executed due to a failed transaction",
                                "The query was not executed due to a cancelled transaction",
                                "Cannot COMMIT: the transaction was aborted due to a prior error"
                              ])

  defp ensure_query_success(body) when is_list(body) do
    body
    |> Enum.with_index()
    |> Enum.filter(fn {statement, _index} -> Map.get(statement, "status") == "ERR" end)
    |> case do
      [] ->
        :ok

      errors ->
        {statement, index} =
          Enum.find(errors, hd(errors), fn {statement, _index} ->
            not MapSet.member?(@generic_transaction_errors, Map.get(statement, "result"))
          end)

        {:error, Error.surreal_error(statement, index)}
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
