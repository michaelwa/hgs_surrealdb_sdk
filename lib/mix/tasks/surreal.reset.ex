defmodule Mix.Tasks.Surreal.Reset do
  @shortdoc "Drops, recreates, and re-migrates the target database"
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

    # The registry lives in a separate namespace/database that the drop above did
    # not touch, so its rows survive. Clear them (install_registry runs first, so
    # this is idempotent) — otherwise Migrations.run would see matching checksums
    # and skip every migration, leaving the recreated database empty.
    Helpers.clear_registry!(client, opts)
    Mix.shell().info("Cleared migration registry for #{namespace}/#{database}.")

    results =
      client
      |> Migrations.run(Helpers.migration_opts(client, opts))
      |> Helpers.unwrap!()

    Helpers.print_run_results(results)
  end
end
