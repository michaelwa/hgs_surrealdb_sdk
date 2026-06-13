defmodule SurrealDB.Repo do
  @moduledoc """
  Friendly, parameterized persistence over `SurrealDB.query/3`, mapping
  `SurrealDB.Schema` modules to SurrealDB tables.

      SurrealDB.Repo.get(client, MyApp.User, "user:abc")
      SurrealDB.Repo.all(client, MyApp.User)
      SurrealDB.Repo.find(client, MyApp.User, %{email: "jane@example.com"})
      SurrealDB.Repo.create(client, MyApp.User, %{name: "Jane", email: "jane@example.com"})
      SurrealDB.Repo.update(client, MyApp.User, "user:abc", %{age: 42})
      SurrealDB.Repo.delete(client, MyApp.User, "user:abc")

  POC scope: simple equality filters only (see `SurrealDB.Repo.FilterBuilder`).
  Record ids are passed as parameters (`$id`); under the HTTP transport these
  are JSON-encoded (quoted). Use `query/5` for raw SurrealQL when you need
  behavior outside this surface.
  """

  alias SurrealDB.{Client, Error, QueryResult}
  alias SurrealDB.Repo.FilterBuilder

  @type client :: Client.t()
  @type schema :: module()

  @spec get(client(), schema(), String.t(), keyword()) ::
          {:ok, struct() | nil} | {:error, Error.t() | SurrealDB.Schema.ValidationError.t()}
  def get(%Client{} = client, schema, id, _opts \\ []) do
    run_one(client, schema, "SELECT * FROM $id", %{id: id})
  end

  @spec all(client(), schema(), map(), keyword()) ::
          {:ok, [struct()]} | {:error, Error.t() | SurrealDB.Schema.ValidationError.t()}
  def all(%Client{} = client, schema, filters \\ %{}, _opts \\ []) do
    with {:ok, {where, filter_vars}} <- FilterBuilder.build(filters) do
      surql = "SELECT * FROM type::table($table)" <> where_suffix(where)
      vars = Map.put(filter_vars, :table, schema.__table__())
      run_many(client, schema, surql, vars)
    end
  end

  @spec find(client(), schema(), map(), keyword()) ::
          {:ok, struct() | nil} | {:error, Error.t() | SurrealDB.Schema.ValidationError.t()}
  def find(%Client{} = client, schema, filters, _opts \\ []) do
    with {:ok, {where, filter_vars}} <- FilterBuilder.build(filters) do
      surql = "SELECT * FROM type::table($table)" <> where_suffix(where) <> " LIMIT 1"
      vars = Map.put(filter_vars, :table, schema.__table__())
      run_one(client, schema, surql, vars)
    end
  end

  @spec create(client(), schema(), map(), keyword()) ::
          {:ok, struct()} | {:error, Error.t() | SurrealDB.Schema.ValidationError.t()}
  def create(%Client{} = client, schema, attrs, _opts \\ []) do
    with {:ok, validated} <- schema.validate(attrs) do
      content = validated |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
      surql = "CREATE type::table($table) CONTENT $attrs"
      vars = %{table: schema.__table__(), attrs: content}
      run_one(client, schema, surql, vars)
    end
  end

  @spec update(client(), schema(), String.t(), map(), keyword()) ::
          {:ok, struct() | nil} | {:error, Error.t() | SurrealDB.Schema.ValidationError.t()}
  def update(%Client{} = client, schema, id, attrs, _opts \\ []) do
    run_one(client, schema, "UPDATE $id MERGE $attrs", %{id: id, attrs: attrs})
  end

  @spec delete(client(), schema(), String.t(), keyword()) ::
          {:ok, struct() | nil} | {:error, Error.t() | SurrealDB.Schema.ValidationError.t()}
  def delete(%Client{} = client, schema, id, _opts \\ []) do
    run_one(client, schema, "DELETE $id RETURN BEFORE", %{id: id})
  end

  @spec query(client(), schema(), iodata(), map(), keyword()) ::
          {:ok, [struct()]} | {:error, Error.t() | SurrealDB.Schema.ValidationError.t()}
  def query(%Client{} = client, schema, surql, vars \\ %{}, _opts \\ []) do
    run_many(client, schema, surql, vars)
  end

  defp run_many(client, schema, surql, vars) do
    with {:ok, %QueryResult{} = result} <- SurrealDB.query(client, surql, vars) do
      hydrate_all(schema, first_records(result))
    end
  end

  defp run_one(client, schema, surql, vars) do
    with {:ok, %QueryResult{} = result} <- SurrealDB.query(client, surql, vars) do
      case first_records(result) do
        [] -> {:ok, nil}
        [record | _rest] -> schema.hydrate(record)
      end
    end
  end

  defp hydrate_all(schema, records) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
      case schema.hydrate(record) do
        {:ok, struct} -> {:cont, {:ok, [struct | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, structs} -> {:ok, Enum.reverse(structs)}
      {:error, _} = error -> error
    end
  end

  defp first_records(%QueryResult{results: [first | _rest]}), do: normalize(first)
  defp first_records(%QueryResult{results: []}), do: []

  defp normalize(nil), do: []
  defp normalize(records) when is_list(records), do: records
  defp normalize(record) when is_map(record), do: [record]
  defp normalize(_other), do: []

  defp where_suffix(""), do: ""
  defp where_suffix(where), do: " " <> where
end
