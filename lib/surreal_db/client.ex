defmodule SurrealDB.Client do
  @moduledoc false

  @type auth ::
          {:basic, %{username: String.t(), password: String.t()}}
          | {:bearer, String.t()}
          | nil

  @type t :: %__MODULE__{
          endpoint: String.t(),
          namespace: String.t(),
          database: String.t(),
          auth: auth(),
          anonymous?: boolean(),
          request_options: keyword()
        }

  defstruct [:endpoint, :namespace, :database, :auth, anonymous?: false, request_options: []]
end
