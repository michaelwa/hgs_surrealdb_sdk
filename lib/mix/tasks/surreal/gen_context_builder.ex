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
end
