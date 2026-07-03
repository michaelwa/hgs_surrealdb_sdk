defmodule SurrealDB.Multi do
  @moduledoc """
  An `Ecto.Multi`-style builder that composes typed, Zoi-validated operations
  and raw SurrealQL into a single atomic `BEGIN ... COMMIT` transaction block.

      multi =
        SurrealDB.Multi.new()
        |> SurrealDB.Multi.create(:user, MyApp.User, %{name: "Jane", email: "jane@example.com"})
        |> SurrealDB.Multi.update(:acct, MyApp.Account, "account:abc", %{balance: 100})
        |> SurrealDB.Multi.let(:owner, "SELECT * FROM $user.id")
        |> SurrealDB.Multi.raw(:rel, "RELATE $owner->owns->$acct")

      MyApp.SurrealStore.transaction(multi)
      #=> {:ok, %{user: %MyApp.User{}, acct: %MyApp.Account{}, owner: [...], rel: [...]}}
      #=> {:error, step_name, reason}

  Every step is LET-bound by its step name, so later `let`/`raw` steps can
  reference earlier results as `$<step_name>`. Step names must be unique,
  valid identifiers; violations raise `ArgumentError` at build time.

  Atomicity is server-side: on any failing statement SurrealDB rolls back the
  whole block and the runner returns `{:error, step_name, reason}`. There are
  never partial writes. `let`/`raw` fragments are wrapped as subquery
  expressions (`LET $name = (<surql>);`), so they must be expressions. DDL
  statements such as `DEFINE` do not belong in a multi.
  """

  alias SurrealDB.Repo.Statement

  @type step_name :: atom()
  @type t :: %__MODULE__{ops: [map()]}

  defstruct ops: []

  @name_pattern ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @variable_pattern ~r/\$([A-Za-z_][A-Za-z0-9_]*)/

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec create(t(), step_name(), module(), map()) :: t()
  def create(%__MODULE__{} = multi, name, schema, attrs)
      when is_atom(name) and is_atom(schema) and is_map(attrs) do
    add(multi, %{name: name, kind: :create, schema: schema, attrs: attrs})
  end

  @spec update(t(), step_name(), module(), String.t(), map()) :: t()
  def update(%__MODULE__{} = multi, name, schema, id, attrs)
      when is_atom(name) and is_atom(schema) and is_map(attrs) do
    add(multi, %{name: name, kind: :update, schema: schema, id: id, attrs: attrs})
  end

  @spec delete(t(), step_name(), module(), String.t()) :: t()
  def delete(%__MODULE__{} = multi, name, schema, id) when is_atom(name) and is_atom(schema) do
    add(multi, %{name: name, kind: :delete, schema: schema, id: id})
  end

  @spec let(t(), step_name(), iodata(), map()) :: t()
  def let(%__MODULE__{} = multi, name, surql, vars \\ %{})
      when is_atom(name) and is_map(vars) do
    add(multi, %{name: name, kind: :let, surql: IO.iodata_to_binary(surql), vars: vars})
  end

  @spec raw(t(), step_name(), iodata(), map()) :: t()
  def raw(%__MODULE__{} = multi, name, surql, vars \\ %{})
      when is_atom(name) and is_map(vars) do
    add(multi, %{name: name, kind: :raw, surql: IO.iodata_to_binary(surql), vars: vars})
  end

  @doc """
  Validates every step and assembles the transaction block.

  Returns `{:ok, surql, vars}` where `surql` is the full
  `BEGIN ... RETURN ... COMMIT` block and `vars` is the merged, per-step
  namespaced variable map, or `{:error, step_name, reason}` for the first
  invalid step. Nothing is sent to the server in that case.
  """
  @spec to_query(t()) :: {:ok, String.t(), map()} | {:error, step_name(), term()}
  def to_query(%__MODULE__{ops: ops}) do
    ops
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], %{}}, fn {op, index}, {:ok, lines, vars} ->
      case build_op(op, index) do
        {:ok, fragment, op_vars} ->
          line = "LET $#{op.name} = (#{fragment});"
          {:cont, {:ok, [line | lines], Map.merge(vars, op_vars)}}

        {:error, reason} ->
          {:halt, {:error, op.name, reason}}
      end
    end)
    |> case do
      {:ok, lines, vars} ->
        return_line =
          "RETURN { " <> Enum.map_join(ops, ", ", &"#{&1.name}: $#{&1.name}") <> " };"

        surql =
          Enum.join(
            ["BEGIN TRANSACTION;"] ++
              Enum.reverse(lines) ++ [return_line, "COMMIT TRANSACTION;"],
            "\n"
          )

        {:ok, surql, vars}

      {:error, name, reason} ->
        {:error, name, reason}
    end
  end

  defp build_op(%{kind: :create, schema: schema, attrs: attrs}, index) do
    namespace_statement(Statement.create(schema, attrs), index)
  end

  defp build_op(%{kind: :update, schema: schema, id: id, attrs: attrs}, index) do
    namespace_statement(Statement.update(schema, id, attrs), index)
  end

  defp build_op(%{kind: :delete, schema: schema, id: id}, index) do
    namespace_statement(Statement.delete(schema, id), index)
  end

  defp build_op(%{kind: kind, surql: surql, vars: vars}, index) when kind in [:let, :raw] do
    namespace_statement({:ok, {surql, vars}}, index)
  end

  defp namespace_statement({:ok, {surql, vars}}, index) do
    string_vars = Map.new(vars, fn {key, value} -> {to_string(key), value} end)

    fragment =
      Regex.replace(@variable_pattern, surql, fn full, name ->
        if Map.has_key?(string_vars, name), do: "$s#{index}_#{name}", else: full
      end)

    namespaced = Map.new(string_vars, fn {key, value} -> {"s#{index}_#{key}", value} end)
    {:ok, fragment, namespaced}
  end

  defp namespace_statement({:error, reason}, _index), do: {:error, reason}

  defp add(%__MODULE__{ops: ops} = multi, op) do
    validate_name!(op.name, ops)
    %{multi | ops: ops ++ [op]}
  end

  defp validate_name!(name, ops) do
    unless Regex.match?(@name_pattern, Atom.to_string(name)) do
      raise ArgumentError,
            "step name #{inspect(name)} must be a valid identifier " <>
              "(letters, digits, underscore - it becomes a $#{name} binding)"
    end

    if Enum.any?(ops, &(&1.name == name)) do
      raise ArgumentError, "step name #{inspect(name)} is already in this multi"
    end
  end
end
