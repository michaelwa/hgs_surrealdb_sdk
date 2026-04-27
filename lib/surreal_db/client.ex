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
          transport: :http | :websocket,
          connection: pid() | nil,
          request_options: keyword()
        }

  defstruct [
    :endpoint,
    :namespace,
    :database,
    :auth,
    :connection,
    anonymous?: false,
    transport: :http,
    request_options: []
  ]
end
