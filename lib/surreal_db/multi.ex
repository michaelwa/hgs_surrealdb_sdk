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

  @type step_name :: atom()
  @type t :: %__MODULE__{ops: [map()]}

  defstruct ops: []

  @name_pattern ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

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
