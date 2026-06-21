defmodule Mix.Tasks.Surreal.Load do
  @shortdoc "Loads a SurrealDB dump file"
  @moduledoc """
  Loads a dump file by executing its SurrealQL contents against the target database.

      $ mix surreal.load --store MyApp.SurrealStore --input dump.surql
  """

  use Mix.Task

  alias Mix.Tasks.Surreal.MigrationTaskHelpers, as: Helpers

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    opts = Helpers.parse!(argv)
    input = Keyword.get(opts, :input) || Mix.raise("surreal.load requires --input FILE")

    client = Helpers.build_client!(opts)
    contents = File.read!(input)

    client
    |> SurrealDB.query(contents)
    |> Helpers.unwrap!()

    Mix.shell().info("Loaded SurrealDB dump from #{input}.")
  end
end
