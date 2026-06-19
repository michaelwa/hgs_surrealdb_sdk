defmodule Mix.Tasks.SurrealDb.Setup do
  @shortdoc "Installs the SurrealDB migration registry and runs migrations"
  @moduledoc """
  Installs the SDK migration registry and runs pending `.surql` migrations.

      $ mix surreal_db.setup --store MyApp.SurrealStore
      $ mix surreal_db.setup --namespace app --database app --path priv/surrealdb_migrations
  """

  use Mix.Task

  alias Mix.Tasks.SurrealDb.MigrationTaskHelpers, as: Helpers
  alias SurrealDB.Migrations

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    opts = Helpers.parse!(argv)
    client = Helpers.build_client!(opts)

    {namespace, database} = Helpers.create_database!(client, opts)
    Mix.shell().info("Created SurrealDB namespace/database #{namespace}/#{database}.")

    client
    |> Migrations.install_registry(Helpers.target_opts(client, opts))
    |> Helpers.unwrap!()

    results =
      client
      |> Migrations.run(Helpers.migration_opts(client, opts))
      |> Helpers.unwrap!()

    Helpers.print_run_results(results)
  end
end
