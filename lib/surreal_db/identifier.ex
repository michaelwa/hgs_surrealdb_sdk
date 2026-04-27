defmodule SurrealDB.Identifier do
  @moduledoc false

  alias SurrealDB.Error

  @table_pattern ~r/\A[A-Za-z][A-Za-z0-9_]*\z/
  @record_pattern ~r/\A([A-Za-z][A-Za-z0-9_]*):([A-Za-z0-9_:-]+)\z/

  @spec validate(String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate(identifier) when is_binary(identifier) do
    value = String.trim(identifier)

    cond do
      value == "" ->
        {:error, invalid_identifier("identifier must not be blank", identifier)}

      Regex.match?(@table_pattern, value) ->
        {:ok, value}

      Regex.match?(@record_pattern, value) ->
        {:ok, value}

      true ->
        {:error, invalid_identifier("identifier is not a valid table or record id", identifier)}
    end
  end

  def validate(identifier) do
    {:error, invalid_identifier("identifier must be a string", identifier)}
  end

  defp invalid_identifier(message, identifier) do
    %Error{
      type: :invalid_identifier,
      message: message,
      details: %{identifier: identifier}
    }
  end
end
