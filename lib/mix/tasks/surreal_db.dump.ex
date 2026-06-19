defmodule Mix.Tasks.SurrealDb.Dump do
  @shortdoc "Dumps the target SurrealDB database"
  @moduledoc """
  Runs `EXPORT DATABASE` and writes the returned result to a file.

      $ mix surreal_db.dump --store MyApp.SurrealStore --output dump.surql
  """

  use Mix.Task

  alias Mix.Tasks.SurrealDb.MigrationTaskHelpers, as: Helpers
  alias SurrealDB.QueryResult

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    opts = Helpers.parse!(argv)
    output = Keyword.get(opts, :output) || Mix.raise("surreal_db.dump requires --output FILE")

    client = Helpers.build_client!(opts)

    %QueryResult{} =
      result =
      client
      |> SurrealDB.query("EXPORT DATABASE;")
      |> Helpers.unwrap!()

    File.write!(output, dump_contents(result))
    Mix.shell().info("Wrote SurrealDB dump to #{output}.")
  end

  defp dump_contents(%QueryResult{results: [contents | _]}) when is_binary(contents), do: contents
  defp dump_contents(%QueryResult{raw: raw}), do: inspect(raw, pretty: true)
end
