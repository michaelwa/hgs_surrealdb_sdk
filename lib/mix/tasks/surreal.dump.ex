defmodule Mix.Tasks.Surreal.Dump do
  @shortdoc "Dumps the target SurrealDB database"
  @moduledoc """
  Exports the target SurrealDB database and writes the dump to a file.

      $ mix surreal.dump --store MyApp.SurrealStore --output dump.surql
  """

  use Mix.Task

  alias Mix.Tasks.Surreal.MigrationTaskHelpers, as: Helpers

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    opts = Helpers.parse!(argv)
    output = Keyword.get(opts, :output) || Mix.raise("surreal.dump requires --output FILE")

    client = Helpers.build_client!(opts)

    contents =
      client
      |> SurrealDB.export()
      |> Helpers.unwrap!()

    File.write!(output, contents)
    Mix.shell().info("Wrote SurrealDB dump to #{output}.")
  end
end
