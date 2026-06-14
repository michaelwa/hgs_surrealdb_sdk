defmodule Mix.Tasks.HgsSurrealdbSdk.Install do
  @shortdoc "Scaffolds SurrealDB SDK connection config into the host app"
  @moduledoc """
  #{@shortdoc}

  Writes a `config :hgs_surrealdb_sdk, connection: [...]` block to
  `config/config.exs`. The SDK's OTP application reads this at boot and refuses
  to start without it.

      $ mix igniter.install hgs_surrealdb_sdk
      $ mix hgs_surrealdb_sdk.install --endpoint http://db:8000 --namespace app --database app

  ## Options

    * `--endpoint`  - SurrealDB HTTP endpoint (default `http://localhost:8000`)
    * `--namespace` - target namespace (default `test`)
    * `--database`  - target database (default `test`)
  """

  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :hgs_surrealdb_sdk,
      example: "mix hgs_surrealdb_sdk.install --namespace app --database app",
      schema: [endpoint: :string, namespace: :string, database: :string]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    opts = igniter.args.options
    endpoint = opts[:endpoint] || "http://localhost:8000"
    namespace = opts[:namespace] || "test"
    database = opts[:database] || "test"

    igniter
    |> Igniter.Project.Config.configure("config.exs", :hgs_surrealdb_sdk, [:connection, :endpoint], endpoint)
    |> Igniter.Project.Config.configure("config.exs", :hgs_surrealdb_sdk, [:connection, :namespace], namespace)
    |> Igniter.Project.Config.configure("config.exs", :hgs_surrealdb_sdk, [:connection, :database], database)
    |> Igniter.Project.Config.configure("config.exs", :hgs_surrealdb_sdk, [:connection, :username], "root")
    |> Igniter.Project.Config.configure("config.exs", :hgs_surrealdb_sdk, [:connection, :password], "root")
    |> Igniter.add_notice("""
    SurrealDB connection config written to config/config.exs.

    The default credentials are root/root for a local dev server. Override them
    (and the endpoint) per environment in config/runtime.exs before deploying,
    and make sure the target namespace/database exist on the server.
    """)
  end
end
