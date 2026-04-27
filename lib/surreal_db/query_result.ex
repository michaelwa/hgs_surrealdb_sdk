defmodule SurrealDB.QueryResult do
  @moduledoc false

  alias SurrealDB.Error

  @type t :: %__MODULE__{
          raw: term(),
          results: [term()],
          statuses: [String.t() | nil]
        }

  defstruct [:raw, results: [], statuses: []]

  @spec from_response(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_response(body) when is_list(body) do
    {:ok,
     %__MODULE__{
       raw: body,
       results: Enum.map(body, &extract_result/1),
       statuses: Enum.map(body, &Map.get(&1, "status"))
     }}
  end

  def from_response(body) when is_map(body) do
    {:ok,
     %__MODULE__{
       raw: body,
       results: [extract_result(body)],
       statuses: [Map.get(body, "status")]
     }}
  end

  def from_response(body), do: {:error, Error.unexpected_response(body)}

  defp extract_result(%{"result" => result}), do: result
  defp extract_result(statement), do: statement
end
