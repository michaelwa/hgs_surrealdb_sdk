defmodule SurrealDB.Live.Subscription do
  @moduledoc false

  @type t :: %__MODULE__{
          id: String.t() | integer(),
          query: String.t(),
          target: pid(),
          status: :active | :stopped
        }

  defstruct [:id, :query, :target, status: :active]
end
