defmodule SurrealDB.Migration do
  @moduledoc """
  Represents a local `.surql` migration file discovered by the SDK.
  """

  @enforce_keys [:filename, :path, :checksum, :contents]
  defstruct [
    :filename,
    :path,
    :checksum,
    :contents
  ]

  @type t :: %__MODULE__{
          filename: String.t(),
          path: Path.t(),
          checksum: String.t(),
          contents: String.t()
        }
end
