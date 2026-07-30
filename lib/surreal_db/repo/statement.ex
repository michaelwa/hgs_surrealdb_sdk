defmodule SurrealDB.Repo.Statement do
  @moduledoc false

  # Shared SurrealQL statement builders used by `SurrealDB.Repo` and
  # `SurrealDB.Multi`.

  alias SurrealDB.Identifier

  @spec create(module(), map()) ::
          {:ok, {String.t(), map()}} | {:error, SurrealDB.Schema.ValidationError.t()}
  def create(schema, attrs) do
    with {:ok, validated} <- schema.validate(attrs) do
      content = validated |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()

      {:ok,
       {"CREATE type::table($__table__) CONTENT $attrs",
        %{__table__: schema.__table__(), attrs: content}}}
    end
  end

  @spec update(module(), String.t(), map()) ::
          {:ok, {String.t(), map()}}
          | {:error, SurrealDB.Error.t() | SurrealDB.Schema.ValidationError.t()}
  def update(schema, id, attrs) do
    with {:ok, identifier} <- Identifier.validate(id),
         {:ok, validated} <- schema.validate_partial(attrs) do
      {:ok, {"UPDATE #{identifier} MERGE $attrs", %{attrs: validated}}}
    end
  end

  @spec delete(module(), String.t()) ::
          {:ok, {String.t(), map()}} | {:error, SurrealDB.Error.t()}
  def delete(_schema, id) do
    with {:ok, identifier} <- Identifier.validate(id) do
      {:ok, {"DELETE #{identifier} RETURN BEFORE", %{}}}
    end
  end
end
