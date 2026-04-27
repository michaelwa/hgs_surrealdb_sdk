defmodule SurrealDB.Variables do
  @moduledoc false

  alias SurrealDB.Error

  @variable_pattern ~r/\$([A-Za-z_][A-Za-z0-9_]*)/

  @spec apply(String.t(), map()) :: {:ok, String.t()} | {:error, Error.t()}
  def apply(query, variables) when is_binary(query) and is_map(variables) do
    normalized =
      Enum.reduce_while(variables, %{}, fn {key, value}, acc ->
        with {:ok, variable_name} <- normalize_key(key),
             {:ok, encoded} <- encode_value(value) do
          {:cont, Map.put(acc, variable_name, encoded)}
        else
          {:error, %Error{} = error} ->
            {:halt, {:error, error}}
        end
      end)

    case normalized do
      {:error, %Error{} = error} ->
        {:error, error}

      encoded_variables ->
        {:ok,
         Regex.replace(@variable_pattern, query, fn _full, variable_name ->
           Map.get(encoded_variables, variable_name, "$" <> variable_name)
         end)}
    end
  end

  defp normalize_key(key) when is_atom(key), do: normalize_key(Atom.to_string(key))

  defp normalize_key(key) when is_binary(key) do
    trimmed = String.trim(key)

    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, trimmed) do
      {:ok, trimmed}
    else
      {:error,
       %Error{
         type: :invalid_variables,
         message: "variable names must be simple identifiers",
         details: %{key: key}
       }}
    end
  end

  defp normalize_key(key) do
    {:error,
     %Error{
       type: :invalid_variables,
       message: "variable names must be atoms or strings",
       details: %{key: key}
     }}
  end

  defp encode_value(value) when is_binary(value), do: {:ok, Jason.encode!(value)}
  defp encode_value(value) when is_boolean(value) or is_number(value), do: {:ok, to_string(value)}
  defp encode_value(nil), do: {:ok, "null"}

  defp encode_value(value) when is_map(value) or is_list(value) do
    {:ok, Jason.encode!(value)}
  rescue
    Protocol.UndefinedError ->
      {:error,
       %Error{
         type: :invalid_variables,
         message: "variable value could not be encoded as JSON",
         details: %{value: inspect(value)}
       }}
  end

  defp encode_value(value) do
    {:error,
     %Error{
       type: :invalid_variables,
       message: "variable value type is not supported",
       details: %{value: inspect(value)}
     }}
  end
end
