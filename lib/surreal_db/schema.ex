defmodule SurrealDB.Schema do
  @moduledoc """
  Defines a table-backed schema using [Zoi](https://hexdocs.pm/zoi).

      defmodule MyApp.User do
        use SurrealDB.Schema

        table "user"

        schema do
          Zoi.object(%{
            id: Zoi.string() |> Zoi.optional(),
            name: Zoi.string(),
            email: Zoi.string()
          })
        end
      end

  A schema module gets a struct (one field per key of the `Zoi.object/1` map)
  plus `__table__/0`, `__schema__/0`, `validate/1`, `hydrate/1`, and `dump/1`.

  The `schema do ... end` block must contain a `Zoi.object(%{...})` with a
  literal field map — the struct fields are read from that map at compile time.
  """

  alias SurrealDB.Schema.ValidationError

  defmacro __using__(_opts) do
    quote do
      import SurrealDB.Schema, only: [table: 1, schema: 1]
      @before_compile SurrealDB.Schema
    end
  end

  @doc "Declares the SurrealDB table name backing this schema."
  defmacro table(name) do
    quote do
      @surreal_table unquote(name)
    end
  end

  @doc "Captures the Zoi schema and derives the struct from its field keys."
  defmacro schema(do: block) do
    field_keys = __extract_field_keys__(block)

    quote do
      defstruct unquote(field_keys)

      @doc false
      def __schema__, do: unquote(block)
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc false
      def __table__, do: @surreal_table

      @doc false
      def validate(params), do: SurrealDB.Schema.__validate__(__schema__(), params)

      @doc false
      def hydrate(record),
        do: SurrealDB.Schema.__hydrate__(__MODULE__, __schema__(), record)

      @doc false
      def dump(data), do: SurrealDB.Schema.__dump__(__schema__(), data)
    end
  end

  @doc false
  # Walks the AST of the `schema do ... end` block and returns the keys of the
  # first map literal it finds (the `Zoi.object(%{...})` field map).
  def __extract_field_keys__(ast) do
    {_ast, keys} =
      Macro.prewalk(ast, nil, fn
        {:%{}, _meta, pairs} = node, nil when is_list(pairs) ->
          {node, Enum.map(pairs, fn {key, _value} -> key end)}

        node, acc ->
          {node, acc}
      end)

    keys || raise ArgumentError, "schema/1 block must contain a Zoi.object(%{...}) literal"
  end

  @doc false
  def __validate__(schema, params) do
    case Zoi.parse(schema, params, coerce: true) do
      {:ok, value} -> {:ok, value}
      {:error, errors} -> {:error, ValidationError.from_zoi(errors)}
    end
  end

  @doc false
  def __hydrate__(module, schema, record) do
    with {:ok, value} <- __validate__(schema, record) do
      {:ok, struct(module, value)}
    end
  end

  @doc false
  def __dump__(schema, %_{} = data) do
    map =
      data
      |> Map.from_struct()
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    __validate__(schema, map)
  end
end
