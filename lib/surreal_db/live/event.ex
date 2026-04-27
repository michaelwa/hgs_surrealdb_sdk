defmodule SurrealDB.Live.Event do
  @moduledoc false

  @type t :: %__MODULE__{
          subscription_id: String.t() | integer(),
          action: String.t() | nil,
          result: term(),
          raw: term()
        }

  defstruct [:subscription_id, :action, :result, :raw]
end
