import Config

# This file is only loaded when hgs_surrealdb_sdk is the root Mix project.
# Consuming applications must provide their own :hgs_surrealdb_sdk config.
config :hgs_surrealdb_sdk, :connection,
  endpoint: System.get_env("SURREALDB_ENDPOINT", "http://localhost:8000"),
  namespace: System.get_env("SURREALDB_NAMESPACE", "test"),
  database: System.get_env("SURREALDB_DATABASE", "test"),
  username: System.get_env("SURREALDB_USERNAME", "root"),
  password: System.get_env("SURREALDB_PASSWORD", "root")
