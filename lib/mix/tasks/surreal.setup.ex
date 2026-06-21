defmodule Mix.Tasks.Surreal.Setup do
  @shortdoc "Installs the SurrealDB migration registry and runs migrations"
  @moduledoc """
  Installs the SDK migration registry and runs pending `.surql` migrations.

      $ mix surreal.setup --store MyApp.SurrealStore
      $ mix surreal.setup --namespace app --database app --path priv/surrealdb_migrations
  """

  use Mix.Task

  alias Mix.Tasks.Surreal.MigrationTaskHelpers, as: Helpers
  alias SurrealDB.Migrations

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    opts = Helpers.parse!(argv)
    client = Helpers.build_client!(opts)

    {namespace, database} = Helpers.create_database!(client, opts)
    Mix.shell().info("Created SurrealDB namespace/database #{namespace}/#{database}.")

    # Migrations.run/2 installs the registry idempotently before running, so
    # there is no separate install_registry step here.
    results =
      client
      |> Migrations.run(Helpers.migration_opts(client, opts))
      |> Helpers.unwrap!()

    Helpers.print_run_results(results)
  end
end
