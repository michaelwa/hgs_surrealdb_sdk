defmodule Mix.Tasks.Surreal do
  @shortdoc "Prints SurrealDB task help"
  @moduledoc """
  Prints the available SurrealDB Mix tasks.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    Mix.shell().info("""
    SurrealDB Mix tasks:

      mix surreal.create              # Creates the target SurrealDB namespace/database
      mix surreal.drop                # Drops the target SurrealDB database
      mix surreal.setup               # Installs the SurrealDB migration registry and runs migrations
      mix surreal.reset               # Clears SurrealDB migration registry rows for a target
      mix surreal.migrate             # Runs pending SurrealDB migrations
      mix surreal.migrations          # Lists recorded SurrealDB migrations
      mix surreal.rollback            # Rolls back recorded SurrealDB migrations
      mix surreal.gen.migration NAME  # Generates a SurrealDB migration
      mix surreal.dump --output FILE  # Dumps the target SurrealDB database
      mix surreal.load --input FILE   # Loads a SurrealDB dump file
    """)
  end
end
