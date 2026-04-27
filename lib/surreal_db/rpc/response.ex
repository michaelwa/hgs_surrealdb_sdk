defmodule SurrealDB.RPC.Response do
  @moduledoc false

  alias SurrealDB.Error

  @type t :: %__MODULE__{
          id: integer() | nil,
          result: term(),
          error: map() | nil,
          raw: term()
        }

  defstruct [:id, :result, :error, :raw]

  @spec success(integer() | nil, term(), term()) :: t()
  def success(id, result, raw) do
    %__MODULE__{id: id, result: result, raw: raw}
  end

  @spec failure(integer() | nil, map(), term()) :: t()
  def failure(id, error, raw) do
    %__MODULE__{id: id, error: error, raw: raw}
  end

  @spec to_error(t()) :: Error.t()
  def to_error(%__MODULE__{error: error, raw: raw}) do
    %Error{
      type: :rpc_error,
      code: error["code"],
      message: error["message"] || "RPC call failed",
      details: Map.drop(error, ["code", "message"]),
      raw: raw
    }
  end
end
