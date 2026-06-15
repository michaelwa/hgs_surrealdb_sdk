defmodule SurrealDB.Telemetry do
  @moduledoc """
  Telemetry events emitted by the SurrealDB SDK.

  (Full event reference filled in Task 7.)
  """

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
end
