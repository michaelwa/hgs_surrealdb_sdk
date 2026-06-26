defmodule Mix.Tasks.Surreal.Create do
  @shortdoc "Creates the target SurrealDB namespace/database"
  @moduledoc """
  Creates the target namespace/database if they do not already exist.

      $ mix surreal.create --store MyApp.SurrealStore
      $ mix surreal.create --namespace app --database app
  """

  use Mix.Task

  alias Mix.Tasks.Surreal.MigrationTaskHelpers, as: Helpers
  alias SurrealDB.Migrations

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    run_create(argv)
  end

  @doc false
  def run_create(argv) do
    opts = Helpers.parse!(argv)
    client = Helpers.build_client!(opts)
    {namespace, database} = Helpers.create_database!(client, opts)

    Mix.shell().info("Created SurrealDB namespace/database #{namespace}/#{database}.")

    client
    |> Migrations.install_registry!(Helpers.target_opts(client, opts))

    Mix.shell().info("Installed SurrealDB migration registry in #{namespace}/#{database}.")
  end
end
