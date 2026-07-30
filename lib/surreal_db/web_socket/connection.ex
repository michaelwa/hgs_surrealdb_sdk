defmodule SurrealDB.WebSocket.Connection do
  @moduledoc false

  use GenServer

  alias SurrealDB.Client
  alias SurrealDB.Error
  alias SurrealDB.Live.Event
  alias SurrealDB.Live.Subscription
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
      :setup_phase,
      :setup_deadline,
      :setup_request_id,
      :setup_timer_ref,
      :setup_waiter,
      :store,
      reconnect?: false,
      reconnect_backoff: 500,
      connect_count: 0,
      pending: %{},
      subscriptions: %{}
    ]
  end

  @spec start_link(Client.t(), keyword()) :: GenServer.on_start()
  def start_link(%Client{} = client, options \\ []) do
    case Keyword.fetch(options, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, {client, options}, name: name)
      :error -> GenServer.start_link(__MODULE__, {client, options})
    end
  end

  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal)
  end

  @spec await_ready(pid(), timeout()) :: :ok | {:error, Error.t()}
  def await_ready(pid, timeout \\ @default_timeout) do
    GenServer.call(pid, :await_ready, timeout + 100)
  catch
    :exit, {:timeout, _} ->
      {:error, %Error{type: :websocket_timeout, message: "websocket setup timed out"}}

    :exit, {:setup_failed, %Error{} = error} ->
      {:error, error}

    :exit, reason ->
      {:error,
       %Error{
         type: :websocket_closed,
         message: "websocket connection is not available",
         raw: reason
       }}
  end

  @spec start_live_query(pid(), String.t(), pid()) ::
          {:ok, Subscription.t()} | {:error, Error.t()}
  def start_live_query(pid, query, target) when is_pid(target) do
    GenServer.call(pid, {:start_live_query, query, target}, @default_timeout + 1_000)
  end

  @spec kill_live_query(pid(), Subscription.t()) :: :ok | {:error, Error.t()}
  def kill_live_query(pid, %Subscription{} = subscription) do
    GenServer.call(pid, {:kill_live_query, subscription}, @default_timeout + 1_000)
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
      setup_complete?: false,
      setup_phase: :connecting,
      store: Keyword.get(options, :store),
      reconnect?: Keyword.get(options, :reconnect, false),
      reconnect_backoff: Keyword.get(options, :reconnect_backoff, 500)
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
        {:noreply, %State{state | socket_pid: socket_pid, setup_phase: :connecting}}

      {:error, reason} ->
        if state.reconnect? do
          state = schedule_reconnect(state)

          {:noreply,
           %State{state | socket_pid: nil, setup_complete?: false, setup_phase: :connecting}}
        else
          {:stop, {:websocket_connect_error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:rpc_call, _request, _timeout}, _from, %State{setup_complete?: false} = state) do
    {:reply,
     {:error, %Error{type: :websocket_connect_error, message: "websocket connection not ready"}},
     state}
  end

  def handle_call(:await_ready, _from, %State{setup_complete?: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:await_ready, from, %State{setup_waiter: nil} = state) do
    {:noreply, %State{state | setup_waiter: from}}
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

  def handle_call(
        {:start_live_query, _query, _target},
        _from,
        %State{setup_complete?: false} = state
      ) do
    {:reply,
     {:error, %Error{type: :websocket_connect_error, message: "websocket connection not ready"}},
     state}
  end

  def handle_call({:start_live_query, query, target}, _from, %State{} = state) do
    request = Request.new("query", [query])

    with {:ok, %Response{result: result}} <- do_roundtrip(state, request),
         {:ok, subscription_id} <- extract_live_query_id(result) do
      subscription = %Subscription{
        id: subscription_id,
        query: query,
        target: target,
        status: :active
      }

      subscriptions = Map.put(state.subscriptions, subscription_id, subscription)
      {:reply, {:ok, subscription}, %State{state | subscriptions: subscriptions}}
    else
      {:error, %Error{} = error} ->
        {:reply, {:error, normalize_live_error(error)}, state}
    end
  end

  def handle_call({:kill_live_query, %Subscription{id: id}}, _from, %State{} = state) do
    case Map.pop(state.subscriptions, id) do
      {nil, _subscriptions} ->
        {:reply,
         {:error, %Error{type: :subscription_not_found, message: "subscription was not found"}},
         state}

      {subscription, subscriptions} ->
        request = Request.new("kill", [id])

        case do_roundtrip(state, request) do
          {:ok, _response} ->
            {:reply, :ok, %State{state | subscriptions: subscriptions}}

          {:error, %Error{} = error} ->
            {:reply, {:error, normalize_live_error(error)},
             %State{state | subscriptions: Map.put(subscriptions, id, subscription)}}
        end
    end
  end

  @impl true
  def handle_info({:websocket_connected, _socket_pid}, %State{} = state) do
    begin_setup(state)
  end

  def handle_info({:websocket_frame, payload}, %State{} = state) do
    case decode_incoming(payload) do
      {:ok, %Response{id: id} = response} when id == state.setup_request_id ->
        handle_setup_response(response, state)

      {:ok, %Response{id: id} = response} ->
        {entry, pending} = Map.pop(state.pending, id)
        maybe_cancel_timer(entry)
        maybe_reply(entry, {:ok, response})
        {:noreply, %State{state | pending: pending}}

      {:live_event, %Event{subscription_id: subscription_id} = event} ->
        route_live_event(state.subscriptions, subscription_id, event)
        {:noreply, state}

      {:error, %Error{} = error} when is_nil(state.setup_request_id) ->
        fail_all_pending(state.pending, error)
        {:stop, {:unexpected_response, error}, %State{state | pending: %{}}}

      {:error, %Error{} = error} ->
        setup_failed(state, error)
    end
  end

  @impl true
  def handle_info({:setup_timeout, request_id}, %State{setup_request_id: request_id} = state) do
    setup_failed(state, %Error{type: :websocket_timeout, message: "websocket setup timed out"})
  end

  def handle_info({:setup_timeout, _request_id}, %State{} = state), do: {:noreply, state}

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

  def handle_info({:websocket_closed, reason}, %State{reconnect?: true} = state) do
    error = %Error{type: :websocket_closed, message: "websocket connection closed", raw: reason}

    if setup_pending?(state) do
      setup_failed(state, error)
    else
      fail_all_pending(state.pending, error)

      emit_connection_event(state, :disconnected, %{
        reason: inspect(reason),
        will_reconnect?: true
      })

      state = schedule_reconnect(state)
      {:noreply, %State{state | pending: %{}, setup_complete?: false, socket_pid: nil}}
    end
  end

  def handle_info({:websocket_closed, reason}, %State{} = state) do
    error = %Error{type: :websocket_closed, message: "websocket connection closed", raw: reason}

    if setup_pending?(state) do
      setup_failed(state, error)
    else
      fail_all_pending(state.pending, error)

      emit_connection_event(state, :disconnected, %{
        reason: inspect(reason),
        will_reconnect?: false
      })

      {:stop, :normal, %State{state | pending: %{}}}
    end
  end

  def handle_info(:reconnect, %State{} = state) do
    {:noreply, state, {:continue, :connect}}
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

  defp begin_setup(%State{} = state) do
    state = %State{
      state
      | setup_complete?: false,
        setup_phase: :connecting,
        setup_deadline: System.monotonic_time(:millisecond) + state.connect_timeout,
        setup_request_id: nil,
        setup_timer_ref: nil
    }

    dispatch_next_setup(state)
  end

  defp dispatch_next_setup(
         %State{
           client: %Client{auth: {:basic, %{username: username, password: password}}},
           setup_phase: phase
         } = state
       )
       when phase in [:connecting, :authenticating] do
    dispatch_setup_request(
      state,
      :authenticating,
      Request.new("signin", [%{user: username, pass: password}])
    )
  end

  defp dispatch_next_setup(
         %State{client: %Client{auth: {:bearer, token}}, setup_phase: phase} = state
       )
       when phase in [:connecting, :authenticating] do
    dispatch_setup_request(state, :authenticating, Request.new("authenticate", [token]))
  end

  defp dispatch_next_setup(%State{client: client, setup_phase: phase} = state)
       when phase in [:connecting, :authenticating, :selecting] do
    dispatch_setup_request(
      state,
      :selecting,
      Request.new("use", [client.namespace, client.database])
    )
  end

  defp dispatch_setup_request(%State{} = state, phase, %Request{} = request) do
    remaining = remaining_setup_timeout(state)

    if remaining <= 0 do
      setup_failed(state, %Error{type: :websocket_timeout, message: "websocket setup timed out"})
    else
      with {:ok, payload} <- encode_request(request),
           :ok <- send_payload(state, request.id, payload) do
        timer_ref = Process.send_after(self(), {:setup_timeout, request.id}, remaining)

        {:noreply,
         %State{
           state
           | setup_phase: phase,
             setup_request_id: request.id,
             setup_timer_ref: timer_ref
         }}
      else
        {:error, %Error{} = error} -> setup_failed(state, error)
      end
    end
  end

  defp handle_setup_response(%Response{error: error, raw: raw}, %State{} = state)
       when not is_nil(error) do
    setup_failed(state, Response.to_error(%Response{error: error, raw: raw}))
  end

  defp handle_setup_response(%Response{}, %State{setup_phase: :authenticating} = state) do
    cancel_setup_timer(state)

    dispatch_next_setup(%State{
      state
      | setup_phase: :selecting,
        setup_request_id: nil,
        setup_timer_ref: nil
    })
  end

  defp handle_setup_response(%Response{}, %State{setup_phase: :selecting} = state) do
    cancel_setup_timer(state)
    finish_setup(%State{state | setup_request_id: nil, setup_timer_ref: nil})
  end

  defp finish_setup(%State{} = state) do
    state = on_connected(state)

    if state.setup_waiter do
      GenServer.reply(state.setup_waiter, :ok)
    end

    {:noreply, %State{state | setup_waiter: nil}}
  end

  defp setup_failed(%State{} = state, %Error{} = error) do
    cancel_setup_timer(state)

    if state.setup_waiter do
      GenServer.reply(state.setup_waiter, {:error, error})
    end

    cond do
      state.reconnect? and error.type in [:websocket_closed, :websocket_timeout] ->
        if is_pid(state.socket_pid), do: state.socket_module.close(state.socket_pid)
        state = schedule_reconnect(state)

        {:noreply,
         %State{
           state
           | pending: %{},
             setup_complete?: false,
             setup_phase: :connecting,
             setup_request_id: nil,
             setup_timer_ref: nil,
             setup_waiter: nil,
             socket_pid: nil
         }}

      true ->
        {:stop, {:setup_failed, error}, %State{state | setup_waiter: nil}}
    end
  end

  defp remaining_setup_timeout(%State{setup_deadline: deadline}) do
    deadline - System.monotonic_time(:millisecond)
  end

  defp setup_pending?(%State{setup_complete?: false, setup_request_id: request_id})
       when not is_nil(request_id),
       do: true

  defp setup_pending?(_state), do: false

  defp cancel_setup_timer(%State{setup_timer_ref: nil}), do: :ok

  defp cancel_setup_timer(%State{setup_timer_ref: timer_ref}) do
    Process.cancel_timer(timer_ref, async: true, info: false)
    :ok
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
        case decode_incoming(payload) do
          {:ok, %Response{} = response} -> {:ok, response}
          {:live_event, _event} -> await_response(timeout)
          {:error, %Error{} = error} -> {:error, error}
        end

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

  defp decode_incoming(payload) when is_binary(payload) do
    with {:ok, decoded} <- Jason.decode(payload) do
      cond do
        Map.has_key?(decoded, "id") ->
          {:ok,
           if is_map(decoded["error"]) do
             Response.failure(decoded["id"], decoded["error"], decoded)
           else
             Response.success(decoded["id"], decoded["result"], decoded)
           end}

        live_event_payload?(decoded) ->
          {:live_event, build_live_event(decoded)}

        true ->
          {:error,
           %Error{
             type: :live_event_decode_error,
             message: "unexpected websocket message shape",
             raw: decoded
           }}
      end
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

  defp live_event_payload?(decoded) do
    is_map(decoded["result"]) and Map.has_key?(decoded["result"], "id")
  end

  defp build_live_event(decoded) do
    result = decoded["result"]

    %Event{
      subscription_id: result["id"],
      action: result["action"],
      result: result["result"],
      raw: decoded
    }
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

  defp route_live_event(subscriptions, subscription_id, event) do
    case Map.get(subscriptions, subscription_id) do
      %Subscription{target: target} when is_pid(target) ->
        send(target, {:surrealdb_live, subscription_id, event})

      _ ->
        :ok
    end
  end

  defp extract_live_query_id([%{"result" => subscription_id} | _])
       when is_binary(subscription_id) or is_integer(subscription_id) do
    {:ok, subscription_id}
  end

  defp extract_live_query_id(subscription_id)
       when is_binary(subscription_id) or is_integer(subscription_id) do
    {:ok, subscription_id}
  end

  defp extract_live_query_id(other) do
    {:error,
     %Error{
       type: :live_query_error,
       message: "live query did not return a subscription id",
       raw: other
     }}
  end

  defp normalize_live_error(%Error{type: :rpc_error} = error),
    do: %Error{error | type: :live_query_error}

  defp normalize_live_error(%Error{type: :unexpected_response} = error),
    do: %Error{error | type: :live_event_decode_error}

  defp normalize_live_error(error), do: error

  defp on_connected(%State{} = state) do
    emit_connection_event(state, :connected, %{reconnect?: state.connect_count > 0})

    %State{
      state
      | setup_complete?: true,
        setup_phase: :ready,
        connect_count: state.connect_count + 1
    }
  end

  defp schedule_reconnect(%State{} = state) do
    emit_connection_event(state, :reconnecting, %{backoff: state.reconnect_backoff})
    Process.send_after(self(), :reconnect, state.reconnect_backoff)
    state
  end

  defp emit_connection_event(%State{client: client, store: store}, name, extra) do
    metadata =
      Map.merge(
        %{
          namespace: client.namespace,
          database: client.database,
          endpoint: client.endpoint,
          store: store
        },
        extra
      )

    :telemetry.execute(
      [:surreal_db, :connection, name],
      %{system_time: System.system_time()},
      metadata
    )
  end
end
