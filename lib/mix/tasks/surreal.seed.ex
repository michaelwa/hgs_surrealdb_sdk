defmodule Mix.Tasks.Surreal.Seed do
  @shortdoc "Runs the SurrealDB repo seed script"
  @moduledoc """
  Evaluates `<repo_path>/seeds.exs` (default `priv/surreal_repo/seeds.exs`) with
  the application started, so the store API is available.

      $ mix surreal.seed
      $ mix surreal.seed --repo-path priv/surreal_repo
  """

  use Mix.Task

  alias Mix.Tasks.Surreal.MigrationTaskHelpers, as: Helpers

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    opts = Helpers.parse!(argv)
    path = Path.join(Helpers.repo_path(opts), "seeds.exs")

    if File.exists?(path) do
      Mix.shell().info("Running seeds from #{path} ...")
      Code.eval_file(path)
      Mix.shell().info("Seeds complete.")
    else
      Mix.shell().info("No seed file at #{path}; nothing to seed.")
    end
  end
end
