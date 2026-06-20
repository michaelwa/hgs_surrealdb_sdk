if Code.ensure_loaded?(Igniter) do
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
      |> Igniter.Project.Config.configure(
        "config.exs",
        app,
        [:surrealdb_stores],
        [store],
        updater: fn zipper -> Igniter.Code.List.prepend_new_to_list(zipper, store) end
      )
      |> Igniter.Project.Application.add_new_child(store)
      |> Igniter.add_task("surreal_db.create", ["--store", inspect(store)])
      |> Igniter.add_notice("""
      SurrealDB store #{inspect(store)} generated and added to your supervision tree.

      Connection config written to config/config.exs (keyed by #{inspect(app)} /
      #{inspect(store)}). The default credentials are root/root for a local dev
      server. Override them (and the endpoint) per environment in
      config/runtime.exs before deploying.

      Confirming these changes will also run `mix surreal_db.create --store #{inspect(store)}`
      to create the "#{namespace}/#{database}" namespace/database on the target
      server. If the server isn't reachable yet, just run that command yourself
      once it is up.

      Call it without an explicit client, e.g. `#{inspect(store)}.query("INFO FOR DB")`.
      """)
    end
  end
else
  defmodule Mix.Tasks.HgsSurrealdbSdk.Install do
    @shortdoc "Scaffolds a SurrealDB.Store module, supervision child, and config into the host app"
    @moduledoc @shortdoc

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'hgs_surrealdb_sdk.install' requires igniter, which is an optional
      dependency that is not installed in this project.

      Install it through igniter's own installer, which fetches igniter and then
      runs this task:

          mix igniter.install hgs_surrealdb_sdk

      Or add igniter to your deps and re-run:

          {:igniter, "~> 0.5", only: [:dev]}

      See https://hexdocs.pm/igniter for details.
      """)

      exit({:shutdown, 1})
    end
  end
end
