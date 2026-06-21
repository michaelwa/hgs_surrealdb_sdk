# Migrations

The migration runner applies `.surql` files in lexicographic filename order and
records state in a SurrealDB registry table.

## Mix tasks

Downstream projects get these tasks when the SDK is added as a dependency:

```bash
mix surreal
mix surreal.create --store MyApp.SurrealStore
mix surreal.drop --store MyApp.SurrealStore --force
mix surreal.setup --store MyApp.SurrealStore
mix surreal.reset --store MyApp.SurrealStore --force
mix surreal.migrate --store MyApp.SurrealStore
mix surreal.migrations --store MyApp.SurrealStore
mix surreal.rollback --store MyApp.SurrealStore --force
mix surreal.gen.migration add_users
mix surreal.dump --store MyApp.SurrealStore --output dump.surql
mix surreal.load --store MyApp.SurrealStore --input dump.surql
```

The names intentionally mirror the common `mix ecto.*` task surface.
`surreal.setup` creates the target namespace/database, installs the SDK
registry, and runs pending migrations. `surreal.reset` drops the target
database, recreates it, installs the registry, and reruns migrations.
`surreal.migrate` only runs pending migrations. `surreal.migrations`
lists recorded registry rows for the target namespace/database.

The tasks read connection settings from a generated `SurrealDB.Store` module
when `--store` is provided. You can also pass connection options directly:

```bash
mix surreal.setup \
  --endpoint http://localhost:8000 \
  --namespace app_ns \
  --database app_db \
  --username root \
  --password root
```

Common task options:

```text
--store MyApp.SurrealStore
--endpoint http://localhost:8000
--namespace app_ns
--database app_db
--username root
--password root
--auth-token token
--anonymous
--migrations-path priv/surrealdb_migrations
--sdk-version 0.1.0
--registry-namespace sdk_meta
--registry-database migration_registry
```

`--migrations-path` defaults to `priv/surrealdb_migrations`; `--path` remains
accepted as a shorter alias. You can pass `--migrations-path` multiple times.
`--namespace` and `--database` are the target namespace/database; registry
metadata is stored in namespace `sdk_meta` and database `migration_registry`
unless overridden.

Migration and rollback task options follow Ecto spelling where they apply:

```text
--step 3
-n 3
--to 20260619000000
--to-exclusive 20260619000000
--all
--allow-failed-rerun
```

`--to` and `--to-exclusive` compare against the leading numeric version in a
filename such as `20260619000000_add_users.surql`.

Generate migration files with:

```bash
mix surreal.gen.migration add_users
mix surreal.gen.migration add_users --migrations-path priv/custom_migrations
```

Rollback support is explicit. Without `--down-path`, rollback only removes the
latest applied registry rows so those migrations can be re-run later. With
`--down-path`, the task runs matching rollback `.surql` files from that
directory before removing registry rows:

```bash
mix surreal.rollback \
  --store MyApp.SurrealStore \
  --step 2 \
  --down-path priv/surrealdb_migrations_down \
  --force
```

`reset`, `drop`, and `rollback` require `--force`.

`surreal.dump` runs `EXPORT DATABASE;` and writes the returned result to
`--output`. `surreal.load` reads `--input` and executes it against the
target database. These depend on the connected SurrealDB server supporting the
export/import SurrealQL you use.

## Elixir API

Install the SDK registry:

```elixir
:ok = SurrealDB.Migrations.install_registry(client)
```

Run migrations:

```elixir
{:ok, results} =
  SurrealDB.Migrations.run(
    client,
    path: "priv/surrealdb_migrations/app",
    target_ns: "app_ns",
    target_db: "app_db",
    sdk_version: "0.1.0"
  )

IO.inspect(results)
```

The default registry location is namespace `sdk_meta` and database
`migration_registry`. Override it with `registry_ns:` and `registry_db:`.

Feature 1 supports HTTP clients. WebSocket clients return a structured
unsupported-client error because WebSocket namespace/database scope is
established when the connection starts.

The SDK ships its registry migration at:

```text
priv/surrealdb_migrations/sdk_registry/001_define_migration_registry.surql
```
