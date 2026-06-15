defmodule SurrealDB.TelemetryTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Telemetry

  test "events/0 lists every emitted event" do
    assert Telemetry.events() == [
             [:surreal_db, :query, :start],
             [:surreal_db, :query, :stop],
             [:surreal_db, :query, :exception],
             [:surreal_db, :connection, :connected],
             [:surreal_db, :connection, :disconnected],
             [:surreal_db, :connection, :reconnecting]
           ]
  end
end
