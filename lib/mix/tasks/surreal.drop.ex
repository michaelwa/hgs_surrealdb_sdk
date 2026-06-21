defmodule Mix.Tasks.Surreal.Drop do
  @shortdoc "Drops the target SurrealDB database"
  @moduledoc """
  Drops the target database.

      $ mix surreal.drop --store MyApp.SurrealStore --force
      $ mix surreal.drop --namespace app --database app --force
  """

  use Mix.Task

  alias Mix.Tasks.Surreal.MigrationTaskHelpers, as: Helpers

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    opts = Helpers.parse!(argv)

    unless Keyword.get(opts, :force, false) do
      Mix.raise("surreal.drop requires --force")
    end

    client = Helpers.build_client!(opts)
    {namespace, database, existed?} = Helpers.drop_database!(client, opts)

    if existed? do
      Mix.shell().info("Dropped SurrealDB database #{namespace}/#{database}.")
    else
      Mix.shell().info("SurrealDB database #{namespace}/#{database} did not exist; nothing to drop.")
    end
  end
end
