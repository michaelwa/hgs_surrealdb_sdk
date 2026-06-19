defmodule Mix.Tasks.SurrealDb.Create do
  @shortdoc "Creates the target SurrealDB namespace/database"
  @moduledoc """
  Creates the target namespace/database if they do not already exist.

      $ mix surreal_db.create --store MyApp.SurrealStore
      $ mix surreal_db.create --namespace app --database app
  """

  use Mix.Task

  alias Mix.Tasks.SurrealDb.MigrationTaskHelpers, as: Helpers

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    opts = Helpers.parse!(argv)
    client = Helpers.build_client!(opts)
    {namespace, database} = Helpers.create_database!(client, opts)

    Mix.shell().info("Created SurrealDB namespace/database #{namespace}/#{database}.")
  end
end
