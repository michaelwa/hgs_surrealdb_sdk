currently have duplicate efforts for installation in the readme and the getting-started


you are in an elixir phoenix project. this project is not the goal, it is only being used for testing the documentation for adding my hgs_surrealdb_sdk library to applications. 

the sdk is located ../../prototypes/hgs_surrealdb_sdk/ 

i am currently looking the README.md and i am testing the ingiter installation process for ease of use can clarity in the overall process.

---
i ran the following:

```
mix igniter.install hgs_surrealdb_sdk@github:michaelwa/hgs_surrealdb_sdk --namespace app2 --database app2
```

which produced this output:

```
Notices:

* SurrealDB store TestIgniter.SurrealStore generated and added to your supervision tree.

  Connection config written to config/config.exs (keyed by :test_igniter /
  TestIgniter.SurrealStore). The default credentials are root/root for a local dev
  server. Override them (and the endpoint) per environment in
  config/runtime.exs before deploying, and make sure the target
  namespace/database exist on the server.

  Call it without an explicit client, e.g. `TestIgniter.SurrealStore.query("INFO FOR DB")`.
```

but when i ran the example from the output above i got and error:

```
iex(1)> TestIgniter.SurrealStore.query("INFO FOR DB")
{:error,
 %SurrealDB.Error{
   type: :surreal_error,
   message: "The namespace 'app2' does not exist",
   status: nil,
   code: nil,
   details: %{"status" => "ERR", "time" => "106.053µs"},
   raw: %{
     "details" => %{
       "details" => %{"name" => "app2"},
       "kind" => "Namespace"
     },
     "kind" => "NotFound",
     "result" => "The namespace 'app2' does not exist",
     "status" => "ERR",
     "time" => "106.053µs",
     "type" => nil
   }
 }}
 ```
why doesn't the install either create the database or indicate what mix command should be run directly after the dependency installation? 

when i did call the following:

```
❯ mix surreal_db.create
```

it created test/test:
```
Created SurrealDB namespace/database test/test.
```

but the config/config.exs defines app2/app2

my goal is to make this process seamless and easy for anyone to follow. if at the end of the igniter installation there are additional mix commands to be run then it should explicity say what they are, in a similar manner as when creating a new phoenix application, which tells the user to change directories, run mix ecto.create, etc.  

---
when using the igniter installation
  notify the user of the mix steps they need to do get the module working properly

```
We are almost there! The following steps are missing:
    $ cd test_igniter
Then configure your database in config/dev.exs and run:
    $ mix ecto.create
Start your Phoenix app with:
    $ mix phx.server
You can also run your app inside IEx (Interactive Elixir) as:
    $ iex -S mix phx.server
```

  make sure migrations is wired up, the migration tables should be run when the 

get the migrations locked down 
  create a mix command that reflects database structures and creates the zio schemas
get mix surreald_sdk commands locked down
explore adding dashboards 
  full phoenix liveview or ??
  telemetry
explore making the sdk an mcp
