defmodule Mix.Tasks.Surreal.Migrations do
  @shortdoc "Lists recorded SurrealDB migrations"
  @moduledoc """
  Lists migration registry rows for the target namespace/database.

      $ mix surreal.migrations --store MyApp.SurrealStore
  """

  use Mix.Task

  alias Mix.Tasks.Surreal.MigrationTaskHelpers, as: Helpers
  alias SurrealDB.Migrations

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    opts = Helpers.parse!(argv)
    client = Helpers.build_client!(opts)

    rows =
      client
      |> Migrations.status(Helpers.target_opts(client, opts))
      |> Helpers.unwrap!()

    Helpers.print_rows(rows)
  end
end
