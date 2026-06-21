defmodule Mix.Tasks.Surreal.Reset do
  @shortdoc "Clears SurrealDB migration registry rows for a target"
  @moduledoc """
  Drops and recreates the target namespace/database, installs the registry, and
  reruns migrations.

  This is destructive and requires `--force`.

      $ mix surreal.reset --store MyApp.SurrealStore --force
  """

  use Mix.Task

  alias Mix.Tasks.Surreal.MigrationTaskHelpers, as: Helpers
  alias SurrealDB.Migrations

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    opts = Helpers.parse!(argv)

    unless Keyword.get(opts, :force, false) do
      Mix.raise("surreal.reset requires --force")
    end

    client = Helpers.build_client!(opts)

    {namespace, database, _existed?} = Helpers.drop_database!(client, opts)
    Mix.shell().info("Dropped SurrealDB database #{namespace}/#{database}.")

    {namespace, database} = Helpers.create_database!(client, opts)
    Mix.shell().info("Created SurrealDB namespace/database #{namespace}/#{database}.")

    Migrations.install_registry!(client, Helpers.target_opts(client, opts))

    results =
      client
      |> Migrations.run(Helpers.migration_opts(client, opts))
      |> Helpers.unwrap!()

    Helpers.print_run_results(results)
  end
end
