defmodule Mix.Tasks.Surreal.Migrate do
  @shortdoc "Runs pending SurrealDB migrations"
  @moduledoc """
  Runs pending `.surql` migrations.

      $ mix surreal.migrate --store MyApp.SurrealStore
      $ mix surreal.migrate --namespace app --database app --path priv/surrealdb_migrations

  Use `--allow-failed-rerun` to retry a migration recorded as failed. Use
  `--registry-namespace` and `--registry-database` to separate registry scope
  from the target, and use `--recover-running` only after confirming that the
  previous runner has stopped.
  """

  use Mix.Task

  alias Mix.Tasks.Surreal.MigrationTaskHelpers, as: Helpers
  alias SurrealDB.Migrations

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    opts = Helpers.parse!(argv)
    client = Helpers.build_client!(opts)

    results =
      client
      |> Migrations.run(Helpers.migration_opts(client, opts))
      |> Helpers.unwrap!()

    Helpers.print_run_results(results)
  end
end
