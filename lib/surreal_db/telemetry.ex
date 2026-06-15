defmodule SurrealDB.Telemetry do
  @moduledoc """
  Telemetry events emitted by the SurrealDB SDK.

  The SDK emits two families of events:

  - **Execution spans** — `[:surreal_db, :query, :start | :stop | :exception]`
    around every query, RPC, CRUD, Repo, and Store call, and around live-query
    start/kill.
  - **Connection lifecycle events** — `[:surreal_db, :connection, :connected |
    :disconnected | :reconnecting]` from the WebSocket connection process.

  Call `SurrealDB.Telemetry.events/0` for the full list of event names (useful
  in `Telemetry.Metrics` specs and in tests).

  ---

  ## Execution span — `[:surreal_db, :query, …]`

  Emitted via `:telemetry.span/3` at `SurrealDB.RPC.call/3` (covering
  `SurrealDB.query/2,3`, `SurrealDB.rpc/3`, all CRUD helpers, `SurrealDB.Repo.*`,
  and `SurrealDB.Store.*`) and at `SurrealDB.Live.start/3` /
  `SurrealDB.Live.kill/2`. Both HTTP and WebSocket transports pass through the
  same boundary, so there is no double-counting.

  | Event | Measurements |
  |-------|--------------|
  | `[:surreal_db, :query, :start]` | `%{system_time: integer, monotonic_time: integer}` |
  | `[:surreal_db, :query, :stop]` | `%{duration: integer, monotonic_time: integer}` |
  | `[:surreal_db, :query, :exception]` | `%{duration: integer, monotonic_time: integer}` |

  `duration` is in `:native` time units (convert with
  `System.convert_time_unit/3`).

  ### Start metadata

  - `:method` — RPC method string. `"query"` for `query/2,3` and all CRUD
    helpers; the literal method for `rpc/3`; `"live"` for `Live.start/3`;
    `"kill"` for `Live.kill/2`. Always present.
  - `:namespace` — SurrealDB namespace. Always present.
  - `:database` — SurrealDB database. Always present.
  - `:transport` — `:http | :websocket`. Always present.
  - `:endpoint` — host URL (e.g. `"http://localhost:8000"`). Auth is never
    included. Always present.
  - `:query` — query text string. Present only when a query string is available
    (i.e. `"query"` and `"live"` methods). See redaction below.
  - `:variable_keys` — sorted list of keys in the variables map (e.g.
    `["id", "name"]`). **Variable values are never emitted.**
  - `:variable_count` — number of variables. Present when a variables map is
    passed.
  - `:params_count` — number of positional params. Present on non-`"query"` RPCs
    that supply a params list.
  - `:telemetry_span_context` — opaque reference supplied by `:telemetry.span/3`
    that correlates the `:start`, `:stop`, and `:exception` events of the same
    call.

  ### Stop metadata

  All start metadata fields are present (`:telemetry.span/3` merges the stop
  metadata map on top of the start metadata), plus:

  - `:result` — `:ok | :error`.
  - `:error` — `%SurrealDB.Error{} | nil`. The struct's `raw` and `details`
    fields may carry response bodies that include application data. The shipped
    default logger emits only `error.type` and `error.message`.

  ### Exception metadata

  All start metadata fields, plus the span-supplied `:kind`, `:reason`, and
  `:stacktrace`. The exception is re-raised after the event fires.

  ---

  ## Connection lifecycle — `[:surreal_db, :connection, …]`

  Discrete events (not spans) emitted from `SurrealDB.WebSocket.Connection`.
  They cover both the F2 supervised connection (`SurrealDB.Store`) and ad-hoc
  `SurrealDB.connect_ws/1` connections.

  Each event carries `%{system_time: integer}` as its measurement and the
  following common metadata: `:namespace`, `:database`, `:endpoint` (same as
  the execution-span fields), and `:store` — the store module (e.g.
  `MyApp.SurrealStore`) when the connection is supervised via `SurrealDB.Store`,
  or `nil` for ad-hoc connections.

  - `[:surreal_db, :connection, :connected]` — `:reconnect?` (`false` on the
    first successful connect; `true` on a later reconnect after a disconnect)
  - `[:surreal_db, :connection, :disconnected]` — `:reason` (inspected string);
    `:will_reconnect?` (boolean)
  - `[:surreal_db, :connection, :reconnecting]` — `:backoff` (delay in
    milliseconds)

  > **Note on `:reconnecting`:** this event fires whenever a connection attempt
  > is scheduled — including after a failed *initial* connect. Consumers may
  > therefore see `:reconnecting` before any `:connected` event if the server is
  > unreachable at startup.

  ---

  ## Metadata safety contract

  - **Query text** — included by default. Disable with:

    ```elixir
    config :hgs_surrealdb_sdk, :telemetry, include_query_text: false
    ```

    When disabled, the `:query` field is replaced with the atom `:"[redacted]"`.

  - **Variable values** — never emitted, regardless of configuration. Only
    `:variable_keys` and `:variable_count` are included.

  - **Error details** — `%SurrealDB.Error{}` in `:error` may carry `raw` and
    `details` fields that include response data. The default logger emits only
    `error.type` and `error.message`; custom handlers should treat `raw`/`details`
    with care.

  ---

  ## Attaching a handler

  Use `:telemetry.attach/4` directly:

  ```elixir
  :telemetry.attach(
    "my-app-surreal-logger",
    [:surreal_db, :query, :stop],
    fn _event, measurements, metadata, _config ->
      IO.inspect({measurements.duration, metadata.method, metadata.result})
    end,
    nil
  )
  ```

  Or use the opt-in default logger (see `attach_default_logger/1`):

  ```elixir
  SurrealDB.Telemetry.attach_default_logger(level: :info)
  ```

  ---

  ## LiveDashboard / Telemetry.Metrics example

  `telemetry_metrics` is **not** a dependency of this SDK. The example below
  belongs in your application's telemetry supervisor:

  ```elixir
  # In your app's Telemetry supervisor metrics/0:
  [
    Telemetry.Metrics.summary("surreal_db.query.stop.duration",
      unit: {:native, :millisecond}, tags: [:method, :namespace, :result]),
    Telemetry.Metrics.counter("surreal_db.connection.disconnected")
  ]
  ```
  """

  require Logger

  alias SurrealDB.Client
  alias SurrealDB.Error

  @query_event [:surreal_db, :query]

  @doc """
  Lists every telemetry event the SDK emits. Useful for `Telemetry.Metrics`
  specs and tests.
  """
  @spec events() :: [[atom()]]
  def events do
    [
      @query_event ++ [:start],
      @query_event ++ [:stop],
      @query_event ++ [:exception],
      [:surreal_db, :connection, :connected],
      [:surreal_db, :connection, :disconnected],
      [:surreal_db, :connection, :reconnecting]
    ]
  end

  @doc false
  @spec start_metadata(Client.t(), String.t(), keyword()) :: map()
  def start_metadata(%Client{} = client, method, fields) do
    %{
      method: method,
      namespace: client.namespace,
      database: client.database,
      transport: client.transport,
      endpoint: client.endpoint
    }
    |> put_query(Keyword.get(fields, :query))
    |> put_variables(Keyword.get(fields, :variables))
    |> put_params(Keyword.get(fields, :params))
  end

  @doc false
  @spec stop_metadata(map(), term()) :: map()
  def stop_metadata(start_meta, :ok), do: Map.merge(start_meta, %{result: :ok, error: nil})
  def stop_metadata(start_meta, {:ok, _}), do: Map.merge(start_meta, %{result: :ok, error: nil})

  def stop_metadata(start_meta, {:error, %Error{} = error}),
    do: Map.merge(start_meta, %{result: :error, error: error})

  def stop_metadata(start_meta, {:error, other}),
    do: Map.merge(start_meta, %{result: :error, error: other})

  @doc false
  @spec span(Client.t(), String.t(), keyword(), (-> result)) :: result when result: term()
  def span(%Client{} = client, method, fields, fun) when is_function(fun, 0) do
    start_meta = start_metadata(client, method, fields)

    :telemetry.span(@query_event, start_meta, fn ->
      result = fun.()
      {result, stop_metadata(start_meta, result)}
    end)
  end

  @doc false
  @spec include_query_text?() :: boolean()
  def include_query_text? do
    :hgs_surrealdb_sdk
    |> Application.get_env(:telemetry, [])
    |> Keyword.get(:include_query_text, true)
  end

  @default_logger_id {__MODULE__, :default_logger}

  @doc """
  Attaches a handler that logs each completed query. Opt-in.

  Options:
    * `:level` — log level (default `:debug`).
  """
  @spec attach_default_logger(keyword()) :: :ok | {:error, :already_exists}
  def attach_default_logger(opts \\ []) do
    level = Keyword.get(opts, :level, :debug)

    :telemetry.attach_many(
      @default_logger_id,
      [[:surreal_db, :query, :stop], [:surreal_db, :query, :exception]],
      &__MODULE__.handle_event/4,
      %{level: level}
    )
  end

  @doc "Detaches the handler attached by `attach_default_logger/1`."
  @spec detach_default_logger() :: :ok | {:error, :not_found}
  def detach_default_logger, do: :telemetry.detach(@default_logger_id)

  @doc false
  def handle_event([:surreal_db, :query, :stop], %{duration: duration}, meta, %{level: level}) do
    Logger.log(level, fn ->
      base =
        "SurrealDB #{meta.method} ns=#{meta.namespace} db=#{meta.database} transport=#{meta.transport} (#{format_ms(duration)}ms)"

      case meta.result do
        :ok ->
          base

        :error ->
          base <> " FAILED #{inspect(error_type(meta.error))}: #{error_message(meta.error)}"
      end
    end)
  end

  def handle_event([:surreal_db, :query, :exception], %{duration: duration}, meta, %{level: level}) do
    Logger.log(level, fn ->
      "SurrealDB #{meta.method} ns=#{meta.namespace} db=#{meta.database} RAISED #{inspect(meta.kind)}: #{inspect(meta.reason)} (#{format_ms(duration)}ms)"
    end)
  end

  defp format_ms(duration) do
    (System.convert_time_unit(duration, :native, :microsecond) / 1000) |> Float.round(2)
  end

  defp error_type(%Error{type: type}), do: type
  defp error_type(other), do: other

  defp error_message(%Error{message: message}), do: message
  defp error_message(other), do: inspect(other)

  defp put_query(meta, nil), do: meta

  defp put_query(meta, query) do
    value = if include_query_text?(), do: IO.iodata_to_binary(query), else: :"[redacted]"
    Map.put(meta, :query, value)
  end

  defp put_variables(meta, nil), do: meta

  defp put_variables(meta, variables) when is_map(variables) do
    meta
    |> Map.put(:variable_keys, variables |> Map.keys() |> Enum.sort())
    |> Map.put(:variable_count, map_size(variables))
  end

  defp put_params(meta, nil), do: meta

  defp put_params(meta, params) when is_list(params),
    do: Map.put(meta, :params_count, length(params))
end
