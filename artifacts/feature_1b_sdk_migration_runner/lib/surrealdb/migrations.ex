defmodule SurrealDB.Migrations do
  @moduledoc """
  Public API for SDK-managed SurrealDB `.surql` migrations.
  """

  alias SurrealDB.Migration.Runner

  @doc """
  Installs the SDK migration registry schema.

  By default this installs into namespace `sdk_meta`, database `migration_registry`.
  """
  defdelegate install_registry(client, opts \\ []), to: Runner

  @doc """
  Bang variant of `install_registry/2`.
  """
  def install_registry!(client, opts \\ []) do
    case install_registry(client, opts) do
      :ok -> :ok
      {:ok, result} -> result
      {:error, reason} -> raise RuntimeError, "failed to install migration registry: #{inspect(reason)}"
    end
  end

  @doc """
  Runs all pending migrations in a local directory.
  """
  defdelegate run(client, opts), to: Runner

  @doc """
  Bang variant of `run/2`.
  """
  def run!(client, opts) do
    case run(client, opts) do
      {:ok, results} -> results
      {:error, reason} -> raise RuntimeError, "migration run failed: #{inspect(reason)}"
    end
  end
end
