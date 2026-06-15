defmodule Mix.Tasks.HgsSurrealdbSdk.Install do
  @shortdoc "Scaffolds a SurrealDB.Store module, supervision child, and config into the host app"
  @moduledoc """
  #{@shortdoc}

  Generates a `<App>.SurrealStore` module backed by `use SurrealDB.Store, otp_app: <app>`,
  adds it to the host application's supervision tree, and writes connection config to
  `config/config.exs` under `config <app>, <App>.SurrealStore`.

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

    app = Igniter.Project.Application.app_name(igniter)
    store = Module.concat(Igniter.Project.Module.module_name_prefix(igniter), SurrealStore)

    igniter
    |> Igniter.Project.Module.create_module(store, """
    use SurrealDB.Store, otp_app: #{inspect(app)}
    """)
    |> Igniter.Project.Config.configure("config.exs", app, [store, :endpoint], endpoint)
    |> Igniter.Project.Config.configure("config.exs", app, [store, :namespace], namespace)
    |> Igniter.Project.Config.configure("config.exs", app, [store, :database], database)
    |> Igniter.Project.Config.configure("config.exs", app, [store, :username], "root")
    |> Igniter.Project.Config.configure("config.exs", app, [store, :password], "root")
    |> Igniter.Project.Application.add_new_child(store)
    |> Igniter.add_notice("""
    SurrealDB store #{inspect(store)} generated and added to your supervision tree.

    Connection config written to config/config.exs under `config #{inspect(app)},
    #{inspect(store)}`. The default credentials are root/root for a local dev
    server. Override them (and the endpoint) per environment in
    config/runtime.exs before deploying, and make sure the target
    namespace/database exist on the server.

    Call it without an explicit client, e.g. `#{inspect(store)}.query("INFO FOR DB")`.
    """)
  end
end
