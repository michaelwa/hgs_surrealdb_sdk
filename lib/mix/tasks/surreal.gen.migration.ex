defmodule Mix.Tasks.Surreal.Gen.Migration do
  @shortdoc "Generates a SurrealDB migration"
  @moduledoc """
  Generates a timestamped `.surql` migration file.

      $ mix surreal.gen.migration add_users
      $ mix surreal.gen.migration add_users --repo-path priv/surreal_repo
  """

  use Mix.Task

  alias Mix.Tasks.Surreal.MigrationTaskHelpers, as: Helpers

  @impl Mix.Task
  def run(argv) do
    {opts, args} = Helpers.parse_with_args!(argv)

    name =
      case args do
        [name] -> name
        [] -> Mix.raise("expected migration name")
        _ -> Mix.raise("expected one migration name, got: #{Enum.join(args, " ")}")
      end

    path = Helpers.migration_path(opts)
    File.mkdir_p!(path)

    filename = timestamp() <> "_" <> normalize_name!(name) <> ".surql"
    full_path = Path.join(path, filename)

    File.write!(full_path, """
    -- #{name}

    -- migrate:up


    -- migrate:down

    """)

    Mix.shell().info("* creating #{full_path}")
  end

  defp timestamp do
    Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
  end

  defp normalize_name!(name) when is_binary(name) do
    normalized =
      name
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]+/, "_")
      |> String.trim("_")

    if normalized == "" do
      Mix.raise("migration name must contain at least one letter or digit")
    else
      normalized
    end
  end
end
