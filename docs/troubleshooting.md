# Troubleshooting

## Igniter compile error from Phoenix LiveView

If compilation fails with an error mentioning `Igniter.Mix.Task.Info` and
`Mix.Tasks.PhoenixLiveView.Upgrade`, for example:

```text
expected Igniter.Mix.Task.Info to return struct metadata, but got none
```

that error is not from this SDK. It comes from the consuming app's
`phoenix_live_view` and `igniter` versions hitting Elixir type-checking while
compiling Phoenix LiveView's Igniter-based upgrade task.

Update the offending dependencies:

```bash
mix deps.update igniter phoenix_live_view
```

## Store fails to boot with missing required options

A supervised store validates config in `start_link`. Missing or misconfigured
config fails the application at boot instead of lazily failing on the first
query.

Common causes:

- The config is inside a Phoenix-generated `if config_env() == :prod do ... end`
  block in `config/runtime.exs`, so it is not applied in dev or test.
- The app atom in `config :my_app, MyApp.SurrealStore` does not match the
  `otp_app:` passed to `use SurrealDB.Store`.

Move required store config to a scope that runs in the environment where the
store starts, and keep the app atom consistent.

## Namespace or database does not exist

A fresh SurrealDB server has no namespaces or databases. Define the target
namespace and database before connecting:

```sql
DEFINE NAMESPACE IF NOT EXISTS app;
DEFINE DATABASE IF NOT EXISTS app;
```

For `curl` examples, see
[Installing SurrealDB](installing-surrealdb.md#create-the-namespace-and-database).

## Git dependency does not pick up new commits

`mix deps.get` honors the SHA locked in `mix.lock`. To advance to the latest
commit on the configured ref:

```bash
mix deps.update hgs_surrealdb_sdk
```

## Direct installer task says Igniter is missing

The SDK keeps Igniter optional so normal installs do not pull it into production.
To run the task directly, add Igniter in dev:

```elixir
{:igniter, "~> 0.5", only: [:dev]}
```

Then run:

```bash
mix hgs_surrealdb_sdk.install --namespace app --database app
```

Or use the source-qualified Igniter installer command:

```bash
mix igniter.install hgs_surrealdb_sdk@github:michaelwa/hgs_surrealdb_sdk --namespace app --database app
```
