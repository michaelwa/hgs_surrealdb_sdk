defmodule Mix.Tasks.SurrealDb do
  @shortdoc "Prints SurrealDB task help"
  @moduledoc """
  Prints the available SurrealDB Mix tasks.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    Mix.shell().info("""
    SurrealDB Mix tasks:

      mix surreal_db.create
      mix surreal_db.drop
      mix surreal_db.setup
      mix surreal_db.reset
      mix surreal_db.migrate
      mix surreal_db.migrations
      mix surreal_db.rollback
      mix surreal_db.gen.migration NAME
      mix surreal_db.dump --output FILE
      mix surreal_db.load --input FILE
    """)
  end
end
