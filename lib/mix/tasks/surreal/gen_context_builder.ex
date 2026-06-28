defmodule Mix.Tasks.Surreal.GenContextBuilder do
  @moduledoc false
  # Pure parsing + rendering helpers for `mix surreal.gen.context`.
  # No Igniter/Mix.Task dependency; only `Mix.raise/1` for validation.

  defmodule Field do
    @moduledoc false
    defstruct [:name, :surreal_type, :zoi_base, optional?: false, modifiers: []]
  end

  @type_map %{
    "string" => {"STRING", "Zoi.string()"},
    "int" => {"INT", "Zoi.integer()"},
    "integer" => {"INT", "Zoi.integer()"},
    "float" => {"FLOAT", "Zoi.float()"},
    "bool" => {"BOOL", "Zoi.boolean()"},
    "boolean" => {"BOOL", "Zoi.boolean()"},
    "datetime" => {"DATETIME", "Zoi.datetime()"},
    "decimal" => {"DECIMAL", "Zoi.decimal()"},
    "uuid" => {"UUID", "Zoi.string()"},
    "array" => {"ARRAY", "Zoi.array(Zoi.any())"},
    "object" => {"OBJECT", "Zoi.object(%{})"}
  }

  @name_re ~r/^[a-z][a-z0-9_]*$/

  def parse_fields!(specs) when is_list(specs), do: Enum.map(specs, &parse_field!/1)

  def parse_field!(spec) when is_binary(spec) do
    case String.split(spec, ":", parts: 2) do
      [name, rest] when name != "" and rest != "" ->
        unless Regex.match?(@name_re, name) do
          Mix.raise(~s(invalid field name "#{name}" in "#{spec}"; must match [a-z][a-z0-9_]*))
        end

        [type_token | mod_tokens] = String.split(rest, "|")
        {surreal_type, zoi_base, optional?} = parse_type!(type_token, spec)
        modifiers = Enum.map(mod_tokens, &parse_modifier!(&1, spec))

        %Field{
          name: name,
          surreal_type: surreal_type,
          zoi_base: zoi_base,
          optional?: optional?,
          modifiers: modifiers
        }

      _ ->
        Mix.raise(~s(invalid field spec "#{spec}"; expected name:type[?][|modifier]...))
    end
  end

  def validate_identifier!(value, label) when is_binary(value) and is_binary(label) do
    if Regex.match?(@name_re, value) do
      :ok
    else
      Mix.raise(~s(invalid #{label} "#{value}"; must match [a-z][a-z0-9_]*))
    end
  end

  def zoi_expr(%Field{zoi_base: base, optional?: false}), do: base
  def zoi_expr(%Field{zoi_base: base, optional?: true}), do: base <> " |> Zoi.optional()"

  def define_field_line(%Field{} = field, table) do
    type = if field.optional?, do: "OPTION<#{field.surreal_type}>", else: field.surreal_type
    "DEFINE FIELD #{field.name} ON #{table} TYPE #{type}#{modifier_clauses(field.modifiers)};"
  end

  def pluralize(word) when is_binary(word) do
    cond do
      Regex.match?(~r/(s|x|z|ch|sh)$/, word) -> word <> "es"
      Regex.match?(~r/[^aeiou]y$/, word) -> String.slice(word, 0..-2//1) <> "ies"
      true -> word <> "s"
    end
  end

  def table_name(schema_arg) when is_binary(schema_arg) do
    schema_arg
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
  end

  # Deterministic clause order: READONLY, DEFAULT, VALUE, ASSERT.
  defp modifier_clauses(modifiers) do
    [:readonly, :default, :value, :assert]
    |> Enum.map(fn key -> {key, List.keyfind(modifiers, key, 0)} end)
    |> Enum.reduce("", fn
      {:readonly, {:readonly, _}}, acc -> acc <> " READONLY"
      {:default, {:default, v}}, acc -> acc <> " DEFAULT #{v}"
      {:value, {:value, v}}, acc -> acc <> " VALUE #{v}"
      {:assert, {:assert, v}}, acc -> acc <> " ASSERT #{v}"
      {_key, nil}, acc -> acc
    end)
  end

  defp parse_type!(token, spec) do
    {base, optional?} =
      if String.ends_with?(token, "?") do
        {String.trim_trailing(token, "?"), true}
      else
        {token, false}
      end

    case base do
      "record:" <> table when table != "" ->
        validate_identifier!(table, "record table name")
        {"record<#{table}>", "Zoi.string()", optional?}

      _ ->
        case Map.fetch(@type_map, base) do
          {:ok, {surreal_type, zoi_base}} ->
            {surreal_type, zoi_base, optional?}

          :error ->
            Mix.raise(~s(unknown type "#{base}" in "#{spec}"; supported: #{supported_types()}))
        end
    end
  end

  defp parse_modifier!(token, spec) do
    case String.split(token, "=", parts: 2) do
      ["readonly"] ->
        {:readonly, nil}

      ["default", v] when v != "" ->
        {:default, v}

      ["assert", v] when v != "" ->
        {:assert, v}

      ["value", v] when v != "" ->
        {:value, v}

      _ ->
        Mix.raise(
          ~s(unknown modifier "#{token}" in "#{spec}"; supported: readonly, default=, assert=, value=)
        )
    end
  end

  defp supported_types do
    (Map.keys(@type_map) ++ ["record:<table>"]) |> Enum.sort() |> Enum.join(", ")
  end

  def timestamp, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")

  def migration_filename(timestamp, migration_name), do: "#{timestamp}_#{migration_name}.surql"

  def migration_body(table, migration_name, fields) do
    field_block =
      case Enum.map(fields, &define_field_line(&1, table)) do
        [] -> ""
        lines -> Enum.join(lines, "\n") <> "\n"
      end

    """
    -- #{migration_name}

    -- migrate:up
    DEFINE TABLE #{table} TYPE NORMAL SCHEMAFULL PERMISSIONS NONE;
    #{field_block}
    -- migrate:down
    REMOVE TABLE #{table};
    """
  end

  def schema_module_body(table, fields) do
    Enum.join(
      [
        ~s(@moduledoc """),
        "SurrealDB schema for the `#{table}` table.",
        ~s("""),
        "use SurrealDB.Schema",
        "",
        "table #{inspect(table)}",
        "",
        "schema do",
        "  Zoi.object(%{",
        zoi_object_lines(fields),
        "  })",
        "end"
      ],
      "\n"
    )
  end

  def context_module_body(context_mod, schema_mod, store_mod, singular, plural) do
    schema_alias = module_last(schema_mod)
    store_alias = module_last(store_mod)

    Enum.join(
      [
        ~s(@moduledoc """),
        "The #{module_last(context_mod)} context.",
        ~s("""),
        "alias #{inspect(schema_mod)}",
        "alias #{inspect(store_mod)}",
        "",
        "def list_#{plural}(filters \\\\ %{}), do: #{store_alias}.all(#{schema_alias}, filters)",
        "def get_#{singular}(id), do: #{store_alias}.get(#{schema_alias}, id)",
        "def create_#{singular}(attrs), do: #{store_alias}.create(#{schema_alias}, attrs)",
        "def update_#{singular}(id, attrs), do: #{store_alias}.update(#{schema_alias}, id, attrs)",
        "def delete_#{singular}(id), do: #{store_alias}.delete(#{schema_alias}, id)"
      ],
      "\n"
    )
  end

  defp zoi_object_lines(fields) do
    [{"id", "Zoi.string() |> Zoi.optional()"} | Enum.map(fields, &{&1.name, zoi_expr(&1)})]
    |> Enum.map(fn {name, expr} -> "    #{name}: #{expr}" end)
    |> Enum.join(",\n")
  end

  defp module_last(mod) do
    mod
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
    |> String.split(".")
    |> List.last()
  end
end
