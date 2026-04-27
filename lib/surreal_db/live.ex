defmodule SurrealDB.Live do
  @moduledoc false

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.Live.Subscription
  alias SurrealDB.WebSocket.Connection

  @spec start(Client.t(), String.t(), keyword()) :: {:ok, Subscription.t()} | {:error, Error.t()}
  def start(%Client{transport: :websocket, connection: pid}, query, opts)
      when is_pid(pid) and is_binary(query) and is_list(opts) do
    target = Keyword.get(opts, :send_to, self())
    Connection.start_live_query(pid, query, target)
  end

  def start(%Client{}, _query, _opts) do
    {:error,
     %Error{
       type: :live_query_error,
       message: "live queries require a websocket connection"
     }}
  end

  @spec kill(Client.t(), Subscription.t()) :: :ok | {:error, Error.t()}
  def kill(%Client{transport: :websocket, connection: pid}, %Subscription{} = subscription)
      when is_pid(pid) do
    Connection.kill_live_query(pid, subscription)
  end

  def kill(%Client{}, _subscription) do
    {:error,
     %Error{
       type: :live_query_error,
       message: "live queries require a websocket connection"
     }}
  end
end
