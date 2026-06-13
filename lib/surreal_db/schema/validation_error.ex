defmodule SurrealDB.Schema.ValidationError do
  @moduledoc """
  Raised/returned when data fails to validate against a `SurrealDB.Schema`.

  Wraps the underlying Zoi validation errors as a flat list of plain maps so
  callers never have to pattern-match on Zoi internals.
  """

  @type normalized_error :: %{path: list(), message: String.t()}
  @type t :: %__MODULE__{message: String.t(), errors: [normalized_error()]}

  defexception message: "validation failed", errors: []

  @doc """
  Build a `ValidationError` from a list of Zoi errors (`%Zoi.Error{}` structs)
  or any maps exposing `:path` and `:message`.
  """
  @spec from_zoi(list()) :: t()
  def from_zoi(errors) when is_list(errors) do
    normalized =
      Enum.map(errors, fn error ->
        %{path: Map.get(error, :path, []) || [], message: Map.get(error, :message)}
      end)

    %__MODULE__{errors: normalized, message: build_message(normalized)}
  end

  defp build_message([]), do: "validation failed"

  defp build_message(normalized) do
    normalized
    |> Enum.map(fn %{path: path, message: message} -> "#{format_path(path)}: #{message}" end)
    |> Enum.join("; ")
  end

  defp format_path([]), do: "(root)"
  defp format_path(path), do: Enum.map_join(path, ".", &to_string/1)
end
