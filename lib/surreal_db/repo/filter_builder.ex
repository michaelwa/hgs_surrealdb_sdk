defmodule SurrealDB.Repo.FilterBuilder do
  @moduledoc """
  Builds a parameterized SurrealQL `WHERE` clause from a simple equality-filter
  map. POC scope: equality only. Values are always parameterized (`$field`);
  field names are validated as simple identifiers and never carry user values.
  """

  alias SurrealDB.Error

  @identifier ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  @spec build(map()) :: {:ok, {String.t(), map()}} | {:error, Error.t()}
  def build(filters) when is_map(filters) do
    filters
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.reduce_while({[], %{}}, fn {key, value}, {clauses, vars} ->
      case validate_key(key) do
        {:ok, name} ->
          {:cont, {[~s(#{name} = $#{name}) | clauses], Map.put(vars, key, value)}}

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
    |> finalize()
  end

  defp finalize({:error, %Error{} = error}), do: {:error, error}
  defp finalize({[], _vars}), do: {:ok, {"", %{}}}

  defp finalize({clauses, vars}) do
    clause = "WHERE " <> (clauses |> Enum.reverse() |> Enum.join(" AND "))
    {:ok, {clause, vars}}
  end

  defp validate_key(key) do
    name = to_string(key)

    if Regex.match?(@identifier, name) do
      {:ok, name}
    else
      {:error,
       %Error{
         type: :invalid_filter,
         message: "filter field names must be simple identifiers",
         details: %{field: key}
       }}
    end
  end
end
