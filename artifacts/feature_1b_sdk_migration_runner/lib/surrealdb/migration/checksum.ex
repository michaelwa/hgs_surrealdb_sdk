defmodule SurrealDB.Migration.Checksum do
  @moduledoc """
  Checksum helpers for `.surql` migration files.
  """

  @doc """
  Returns a stable SHA-256 checksum with a `sha256:` prefix.
  """
  @spec sha256(String.t()) :: String.t()
  def sha256(contents) when is_binary(contents) do
    digest =
      :crypto.hash(:sha256, contents)
      |> Base.encode16(case: :lower)

    "sha256:" <> digest
  end

  @doc """
  Returns a deterministic migration key for one target namespace/database/file tuple.
  """
  @spec migration_key(String.t(), String.t(), String.t()) :: String.t()
  def migration_key(target_ns, target_db, filename)
      when is_binary(target_ns) and is_binary(target_db) and is_binary(filename) do
    [target_ns, target_db, filename]
    |> Enum.join("/")
    |> sha256()
  end
end
