# Migrations

The migration runner applies `.surql` files in lexicographic filename order and
records state in a SurrealDB registry table.

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
