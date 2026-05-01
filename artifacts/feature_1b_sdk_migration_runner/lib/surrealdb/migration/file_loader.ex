defmodule SurrealDB.Migration.FileLoader do
  @moduledoc """
  Discovers and loads local `.surql` migration files.
  """

  alias SurrealDB.Migration
  alias SurrealDB.Migration.Checksum

  @doc """
  Loads `.surql` files from `path`, sorted by filename ascending.
  """
  @spec load!(Path.t()) :: [Migration.t()]
  def load!(path) when is_binary(path) do
    path
    |> Path.expand()
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".surql"))
    |> Enum.sort()
    |> Enum.map(fn filename ->
      full_path = Path.join(path, filename)
      contents = File.read!(full_path)

      %Migration{
        filename: filename,
        path: full_path,
        contents: contents,
        checksum: Checksum.sha256(contents)
      }
    end)
  end
end
