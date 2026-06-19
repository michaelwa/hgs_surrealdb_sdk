defmodule Mix.Tasks.SurrealDb.Drop do
  @shortdoc "Drops the target SurrealDB database"
  @moduledoc """
  Drops the target database.

      $ mix surreal_db.drop --store MyApp.SurrealStore --force
      $ mix surreal_db.drop --namespace app --database app --force
  """

  use Mix.Task

  alias Mix.Tasks.SurrealDb.MigrationTaskHelpers, as: Helpers

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    opts = Helpers.parse!(argv)

    unless Keyword.get(opts, :force, false) do
      Mix.raise("surreal_db.drop requires --force")
    end

    client = Helpers.build_client!(opts)
    {namespace, database} = Helpers.drop_database!(client, opts)

    Mix.shell().info("Dropped SurrealDB database #{namespace}/#{database}.")
  end
end
