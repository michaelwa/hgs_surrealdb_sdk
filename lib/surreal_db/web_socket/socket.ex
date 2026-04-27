defmodule SurrealDB.WebSocket.Socket do
  @moduledoc false

  use WebSockex

  def start_link(owner, url, headers, options \\ []) do
    state = %{owner: owner}
    ws_opts = Keyword.take(options, [:name, :debug, :async, :handle_initial_conn_failure])
    WebSockex.start_link(url, __MODULE__, state, Keyword.put(ws_opts, :extra_headers, headers))
  end

  def send_text(pid, payload) do
    WebSockex.cast(pid, {:send_text, payload})
  end

  def close(pid) do
    WebSockex.cast(pid, :close)
  end

  @impl true
  def handle_connect(_conn, state) do
    send(state.owner, {:websocket_connected, self()})
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, payload}, state) do
    send(state.owner, {:websocket_frame, payload})
    {:ok, state}
  end

  @impl true
  def handle_cast({:send_text, payload}, state) do
    {:reply, {:text, payload}, state}
  end

  def handle_cast(:close, state) do
    {:close, state}
  end

  @impl true
  def handle_disconnect(reason, state) do
    send(state.owner, {:websocket_closed, reason})
    {:ok, state}
  end
end
