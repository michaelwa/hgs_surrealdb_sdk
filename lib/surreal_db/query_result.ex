defmodule SurrealDB.QueryResult do
  @moduledoc false

  alias SurrealDB.Error

  @type statement :: %{
          status: atom() | nil,
          time: String.t() | nil,
          result: term(),
          raw: map()
        }

  @type t :: %__MODULE__{
          status: atom(),
          time: String.t() | nil,
          result: term(),
          statements: [statement()],
          raw: term()
        }

  defstruct [:status, :time, :result, statements: [], raw: nil]

  @spec from_response(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_response(body) when is_list(body) do
    statements = Enum.map(body, &normalize_statement/1)
    first = List.first(statements)

    {:ok,
     %__MODULE__{
       status: aggregate_status(statements),
       time: first && first.time,
       result: first && first.result,
       statements: statements,
       raw: body
     }}
  end

  def from_response(body) when is_map(body) do
    {:ok,
     %__MODULE__{
       status: :ok,
       result: body,
       statements: [%{status: :ok, time: nil, result: body, raw: body}],
       raw: body
     }}
  end

  def from_response(body) do
    {:error,
     Error.decode_failure(
       inspect(body),
       "unexpected response shape"
     )}
  end

  defp normalize_statement(statement) do
    %{
      status: normalize_status(Map.get(statement, "status")),
      time: Map.get(statement, "time"),
      result: Map.get(statement, "result"),
      raw: statement
    }
  end

  defp normalize_status("OK"), do: :ok
  defp normalize_status("ERR"), do: :error
  defp normalize_status(nil), do: nil
  defp normalize_status(other) when is_binary(other), do: String.downcase(other) |> String.to_atom()

  defp aggregate_status(statements) do
    if Enum.any?(statements, &(&1.status == :error)), do: :error, else: :ok
  end
end
