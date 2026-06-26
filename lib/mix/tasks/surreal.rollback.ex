defmodule Mix.Tasks.Surreal.Rollback do
  @shortdoc "Rolls back recorded SurrealDB migrations"
  @moduledoc """
  Rolls back the latest recorded migrations.

  Runs `-- migrate:down` sections from the matching migration files before
  removing registry rows. Migrations without a down section are removed from the
  registry only.

      $ mix surreal.rollback --store MyApp.SurrealStore --force
      $ mix surreal.rollback --store MyApp.SurrealStore --steps 2 --force
  """

  use Mix.Task

  alias Mix.Tasks.Surreal.MigrationTaskHelpers, as: Helpers
  alias SurrealDB.Migrations

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    opts = Helpers.parse!(argv)

    unless Keyword.get(opts, :force, false) do
      Mix.raise("surreal.rollback requires --force")
    end

    client = Helpers.build_client!(opts)

    results =
      client
      |> Migrations.rollback(Helpers.target_opts(client, opts))
      |> Helpers.unwrap!()

    reverted = Enum.count(results, & &1.reverted?)
    registry_only = Enum.reject(results, & &1.reverted?)

    Mix.shell().info(
      "Rolled back #{length(results)} migration(s); #{reverted} schema reversal(s) ran."
    )

    Enum.each(results, fn result ->
      status = if result.reverted?, do: "reverted", else: "registry-only"
      Mix.shell().info("  #{status} #{result.filename}")
    end)

    if registry_only != [] do
      Mix.shell().error("""
      warning: #{length(registry_only)} migration(s) had no `-- migrate:down` section.
      Their registry rows were removed, but the schema was NOT changed. Add a
      `-- migrate:down` section to make them reversible, or use `mix surreal.reset`.
      """)
    end
  end
end
