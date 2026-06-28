if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Surreal.Gen.Context do
    @shortdoc "Generates a SurrealDB context, Zoi schema, and migration"
    @moduledoc """
    #{@shortdoc}

    Generates a context module, a `SurrealDB.Schema` (Zoi) module nested under it, and a
    timestamped `.surql` migration in the host application.

        $ mix surreal.gen.context Accounts User name:string email:string age:int
        $ mix surreal.gen.context Accounts User "created_at:datetime|readonly|default=time::now()"

    ## Field syntax

        name:type[?][|modifier]...

    `?` marks the field optional (`OPTION<TYPE>` + `Zoi.optional()`). Modifiers are
    `|`-delimited and emitted into the migration only: `readonly`, `default=<surql>`,
    `assert=<surql>`, `value=<surql>`.

    ## Options

      * `--table`     - SurrealDB table name (default: snake_case of the schema)
      * `--store`     - store module the context delegates to (default: `<App>.SurrealStore`)
      * `--plural`    - plural used in function names (default: naive pluralization)
      * `--repo-path` - migrations root (default: resolved from store config / `priv/surreal_repo`)
    """

    use Igniter.Mix.Task

    alias Mix.Tasks.Surreal.GenContextBuilder, as: Builder
    alias Mix.Tasks.Surreal.MigrationTaskHelpers, as: Helpers

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :hgs_surrealdb_sdk,
        example: "mix surreal.gen.context Accounts User name:string email:string",
        positional: [:context, :schema, fields: [rest: true]],
        schema: [
          table: :string,
          store: :string,
          plural: :string,
          repo_path: :string,
          migration_timestamp: :string
        ]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      %{context: context_arg, schema: schema_arg, fields: field_specs} = igniter.args.positional
      opts = igniter.args.options

      prefix = Igniter.Project.Module.module_name_prefix(igniter)
      context_mod = Module.concat(prefix, context_arg)
      schema_mod = Module.concat([prefix, context_arg, schema_arg])
      store_mod = resolve_store(opts, prefix)

      fields = Builder.parse_fields!(field_specs)
      table = opts[:table] || Builder.table_name(schema_arg)
      Builder.validate_identifier!(table, "table name")
      plural = opts[:plural] || Builder.pluralize(table)
      Builder.validate_identifier!(plural, "plural")
      migration_name = "create_#{table}"
      timestamp = opts[:migration_timestamp] || Builder.timestamp()

      migration_path =
        Helpers.repo_path(opts)
        |> Path.join("migrations")
        |> Path.join(Builder.migration_filename(timestamp, migration_name))

      igniter
      |> Igniter.Project.Module.create_module(
        schema_mod,
        Builder.schema_module_body(table, fields)
      )
      |> Igniter.Project.Module.create_module(
        context_mod,
        Builder.context_module_body(context_mod, schema_mod, store_mod, table, plural)
      )
      |> Igniter.create_new_file(
        migration_path,
        Builder.migration_body(table, migration_name, fields)
      )
      |> Igniter.add_notice("""
      Generated #{inspect(context_mod)}, #{inspect(schema_mod)}, and
      #{migration_path}.

      Apply the migration with `mix surreal.migrate`.
      """)
    end

    defp resolve_store(opts, prefix) do
      case opts[:store] do
        nil -> Module.concat(prefix, SurrealStore)
        store when is_binary(store) -> Module.concat([store])
      end
    end
  end
else
  defmodule Mix.Tasks.Surreal.Gen.Context do
    @shortdoc "Generates a SurrealDB context, Zoi schema, and migration"
    @moduledoc @shortdoc

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'surreal.gen.context' requires igniter, which is an optional dependency
      that is not installed in this project.

      Install it through igniter's own installer:

          mix igniter.install hgs_surrealdb_sdk

      Or add igniter to your deps and re-run:

          {:igniter, "~> 0.5", only: [:dev]}
      """)

      exit({:shutdown, 1})
    end
  end
end
