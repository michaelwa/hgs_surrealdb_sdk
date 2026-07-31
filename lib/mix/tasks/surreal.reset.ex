defmodule Mix.Tasks.Surreal.Reset do
  @shortdoc "Drops, recreates, and re-migrates the target database"
  @moduledoc """
  Drops and recreates the target namespace/database, installs the registry, and
  reruns migrations.

  This is destructive and requires `--force`.

  Registry scope defaults to `sdk_meta` / `migration_registry` and can be
  overridden with `--registry-namespace` and `--registry-database`.

      $ mix surreal.reset --store MyApp.SurrealStore --force
  """

  use Mix.Task

  alias Mix.Tasks.Surreal.MigrationTaskHelpers, as: Helpers
  alias SurrealDB.Migrations

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    opts = Helpers.parse!(argv)

    unless Keyword.get(opts, :force, false) do
      Mix.raise("surreal.reset requires --force")
    end

    client = Helpers.build_client!(opts)

    {namespace, database, _existed?} = Helpers.drop_database!(client, opts)
    Mix.shell().info("Dropped SurrealDB database #{namespace}/#{database}.")

    {namespace, database} = Helpers.create_database!(client, opts)
    Mix.shell().info("Created SurrealDB namespace/database #{namespace}/#{database}.")

    {registry_namespace, registry_database} =
      Helpers.create_database!(client, Helpers.registry_scope_opts(opts))

    Mix.shell().info(
      "Created migration registry namespace/database #{registry_namespace}/#{registry_database}."
    )

    registry_opts = Helpers.target_opts(client, opts)

    client
    |> Migrations.install_registry(registry_opts)
    |> Helpers.unwrap!()

    client
    |> Migrations.reset(registry_opts)
    |> Helpers.unwrap!()

    results =
      client
      |> Migrations.run(Helpers.migration_opts(client, opts))
      |> Helpers.unwrap!()

    Helpers.print_run_results(results)
  end
end
