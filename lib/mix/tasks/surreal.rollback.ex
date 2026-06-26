defmodule Mix.Tasks.Surreal.Rollback do
  @shortdoc "Rolls back recorded SurrealDB migrations"
  @moduledoc """
  Rolls back the latest recorded migrations.

  Without `--down-path`, this only removes registry rows. With `--down-path`, the
  task runs matching `.surql` files from that directory before removing rows.

      $ mix surreal.rollback --store MyApp.SurrealStore --force
      $ mix surreal.rollback --store MyApp.SurrealStore --steps 2 --down-path priv/surrealdb_migrations_down --force
  """

  use Mix.Task

  alias Mix.Tasks.Surreal.MigrationTaskHelpers, as: Helpers
  alias SurrealDB.Migrations

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    opts = Helpers.parse!(argv)

    unless Keyword.get(opts, :force, false) do
      Mix.raise("surreal.rollback requires --force")
    end

    client = Helpers.build_client!(opts)

    rows =
      client
      |> Migrations.rollback(Helpers.target_opts(client, opts))
      |> Helpers.unwrap!()

    Mix.shell().info("Rolled back #{length(rows)} migration registry row(s).")
    Helpers.print_rows(rows)

    if rows != [] and not down_path_given?(opts) do
      Mix.shell().error("""
      warning: no --down-path was given, so no down-migrations were run.
      The registry rows above were removed, but the schema in the target \
      database was NOT changed. Re-run with --down-path to execute reversal \
      `.surql` files, or drop/recreate the database with `mix surreal.reset`.
      """)
    end
  end

  defp down_path_given?(opts) do
    case Keyword.get(opts, :down_path) do
      nil -> false
      "" -> false
      _ -> true
    end
  end
end
