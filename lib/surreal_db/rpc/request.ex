defmodule SurrealDB.RPC.Request do
  @moduledoc false

  @type t :: %__MODULE__{
          id: integer(),
          method: String.t(),
          params: list()
        }

  defstruct [:id, :method, params: []]

  @spec new(String.t(), list()) :: t()
  def new(method, params \\ []) when is_binary(method) and is_list(params) do
    %__MODULE__{
      id: System.unique_integer([:positive, :monotonic]),
      method: method,
      params: params
    }
  end
end
