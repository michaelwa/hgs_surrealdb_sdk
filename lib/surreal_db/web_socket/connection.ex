defmodule SurrealDB.WebSocket.Connection do
  @moduledoc false

  use GenServer

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.RPC.Request
  alias SurrealDB.RPC.Response

  @default_timeout 5_000

  defmodule State do
    @moduledoc false
    defstruct [
      :client,
      :socket_pid,
      :socket_module,
      :connect_timeout,
      :setup_complete?,
      pending: %{}
    ]
  end

  @spec start_link(Client.t(), keyword()) :: GenServer.on_start()
  def start_link(%Client{} = client, options \\ []) do
    GenServer.start_link(__MODULE__, {client, options})
  end

  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal)
  end

  @spec call(pid(), Request.t(), timeout()) :: {:ok, Response.t()} | {:error, Error.t()}
  def call(pid, %Request{} = request, timeout \\ @default_timeout) do
    GenServer.call(pid, {:rpc_call, request, timeout}, timeout + 1_000)
  catch
    :exit, {:timeout, _} ->
      {:error, %Error{type: :websocket_timeout, message: "websocket request timed out"}}

    :exit, reason ->
      {:error,
       %Error{
         type: :websocket_closed,
         message: "websocket connection is not available",
         raw: reason
       }}
  end

  @impl true
  def init({client, options}) do
    socket_module = Keyword.get(options, :socket_module, SurrealDB.WebSocket.Socket)
    connect_timeout = Keyword.get(options, :timeout, @default_timeout)

    state = %State{
      client: client,
      socket_module: socket_module,
      connect_timeout: connect_timeout,
      setup_complete?: false
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, %State{} = state) do
    headers = websocket_headers(state.client)

    case state.socket_module.start_link(
           self(),
           state.client.endpoint,
           headers,
           state.client.request_options
         ) do
      {:ok, socket_pid} ->
        {:noreply, %State{state | socket_pid: socket_pid}}

      {:error, reason} ->
        {:stop, {:websocket_connect_error, reason}, state}
    end
  end

  @impl true
  def handle_call({:rpc_call, _request, _timeout}, _from, %State{setup_complete?: false} = state) do
    {:reply,
     {:error, %Error{type: :websocket_connect_error, message: "websocket connection not ready"}},
     state}
  end

  def handle_call({:rpc_call, %Request{} = request, timeout}, from, %State{} = state) do
    with {:ok, payload} <- encode_request(request),
         :ok <- send_payload(state, request.id, payload) do
      timer_ref = Process.send_after(self(), {:rpc_timeout, request.id}, timeout)
      pending = Map.put(state.pending, request.id, %{from: from, timer_ref: timer_ref})
      {:noreply, %State{state | pending: pending}}
    else
      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_info({:websocket_connected, _socket_pid}, %State{} = state) do
    case perform_setup(state) do
      {:ok, %State{} = new_state} -> {:noreply, %State{new_state | setup_complete?: true}}
      {:error, reason, new_state} -> {:stop, reason, new_state}
    end
  end

  def handle_info({:websocket_frame, payload}, %State{} = state) do
    case decode_response(payload) do
      {:ok, %Response{id: id} = response} ->
        {entry, pending} = Map.pop(state.pending, id)
        maybe_cancel_timer(entry)
        maybe_reply(entry, {:ok, response})
        {:noreply, %State{state | pending: pending}}

      {:error, %Error{} = error} ->
        fail_all_pending(state.pending, error)
        {:stop, {:unexpected_response, error}, %State{state | pending: %{}}}
    end
  end

  def handle_info({:rpc_timeout, request_id}, %State{} = state) do
    case Map.pop(state.pending, request_id) do
      {nil, pending} ->
        {:noreply, %State{state | pending: pending}}

      {entry, pending} ->
        GenServer.reply(
          entry.from,
          {:error, %Error{type: :websocket_timeout, message: "websocket request timed out"}}
        )

        {:noreply, %State{state | pending: pending}}
    end
  end

  def handle_info({:websocket_closed, reason}, %State{} = state) do
    error = %Error{type: :websocket_closed, message: "websocket connection closed", raw: reason}
    fail_all_pending(state.pending, error)
    {:stop, :normal, %State{state | pending: %{}}}
  end

  @impl true
  def terminate(_reason, %State{socket_pid: pid, socket_module: socket_module})
      when is_pid(pid) do
    _ = socket_module.close(pid)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp websocket_headers(%Client{auth: auth}) do
    case auth do
      {:basic, %{username: username, password: password}} ->
        [{"authorization", "Basic " <> Base.encode64("#{username}:#{password}")}]

      {:bearer, token} ->
        [{"authorization", "Bearer " <> token}]

      nil ->
        []
    end
  end

  defp perform_setup(%State{} = state) do
    with :ok <- maybe_signin(state),
         :ok <- use_namespace_database(state) do
      {:ok, state}
    else
      {:error, %Error{} = error} -> {:error, {:setup_failed, error}, state}
    end
  end

  defp maybe_signin(
         %State{client: %Client{auth: {:basic, %{username: username, password: password}}}} =
           state
       ) do
    request = Request.new("signin", [%{user: username, pass: password}])

    case do_roundtrip(state, request) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp maybe_signin(%State{client: %Client{auth: {:bearer, token}}} = state) do
    request = Request.new("authenticate", [token])

    case do_roundtrip(state, request) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp maybe_signin(_state), do: :ok

  defp use_namespace_database(%State{client: client} = state) do
    request = Request.new("use", [%{ns: client.namespace, db: client.database}])

    case do_roundtrip(state, request) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp do_roundtrip(%State{} = state, %Request{} = request) do
    with {:ok, payload} <- encode_request(request),
         :ok <- send_payload(state, request.id, payload),
         {:ok, %Response{} = response} <- await_response(state.connect_timeout) do
      if response.error, do: {:error, Response.to_error(response)}, else: {:ok, response}
    end
  end

  defp await_response(timeout) do
    receive do
      {:websocket_frame, payload} ->
        decode_response(payload)

      {:websocket_closed, reason} ->
        {:error,
         %Error{type: :websocket_closed, message: "websocket connection closed", raw: reason}}
    after
      timeout ->
        {:error, %Error{type: :websocket_timeout, message: "websocket request timed out"}}
    end
  end

  defp encode_request(%Request{} = request) do
    Jason.encode(%{
      id: request.id,
      method: request.method,
      params: request.params
    })
    |> case do
      {:ok, payload} ->
        {:ok, payload}

      {:error, reason} ->
        {:error,
         %Error{type: :rpc_error, message: "failed to encode websocket RPC request", raw: reason}}
    end
  end

  defp decode_response(payload) when is_binary(payload) do
    with {:ok, decoded} <- Jason.decode(payload) do
      {:ok,
       if is_map(decoded["error"]) do
         Response.failure(decoded["id"], decoded["error"], decoded)
       else
         Response.success(decoded["id"], decoded["result"], decoded)
       end}
    else
      {:error, reason} ->
        {:error,
         %Error{
           type: :unexpected_response,
           message: "failed to decode websocket response",
           raw: reason
         }}
    end
  end

  defp send_payload(%State{socket_pid: pid, socket_module: socket_module}, _request_id, payload)
       when is_pid(pid) do
    case socket_module.send_text(pid, payload) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, %Error{type: :websocket_send_error, message: inspect(reason), raw: reason}}
    end
  end

  defp maybe_cancel_timer(nil), do: :ok

  defp maybe_cancel_timer(%{timer_ref: timer_ref}),
    do: Process.cancel_timer(timer_ref, async: true, info: false)

  defp maybe_reply(nil, _reply), do: :ok
  defp maybe_reply(%{from: from}, reply), do: GenServer.reply(from, reply)

  defp fail_all_pending(pending, error) do
    Enum.each(pending, fn {_id, entry} ->
      maybe_cancel_timer(entry)
      GenServer.reply(entry.from, {:error, error})
    end)
  end
end
