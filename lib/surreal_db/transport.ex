defmodule SurrealDB.Transport do
  @moduledoc false

  alias SurrealDB.Client
  alias SurrealDB.RPC.Request
  alias SurrealDB.RPC.Response

  @callback call(Client.t(), Request.t()) :: {:ok, Response.t()} | {:error, SurrealDB.Error.t()}
end
