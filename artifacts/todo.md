task #5
"mix surreal.drop --namespace app3 --database app3 --force" did not drop the namespace or the database but did reply with "Dropped SurrealDB database app3/app3."

Also "mix surreal.drop --database app3 --force" did not drop the database but did reply with "Dropped SurrealDB database app3/app3."

i use ns=app3 and db=app3 because was not cuurently connected to either of them.

i stopped the application and stopped Surrealist to make sure there were no active connections then ran the following.

"mix surreal.reset --force" produces an error: 

```error
Dropped SurrealDB database app2/app2.
Created SurrealDB namespace/database app2/app2.
** (FunctionClauseError) no function clause matching in Mix.Tasks.Surreal.MigrationTaskHelpers.unwrap!/1

    The following arguments were given to Mix.Tasks.Surreal.MigrationTaskHelpers.unwrap!/1:

        # 1
        :ok

    Attempted function clauses (showing 2 out of 2):

        def unwrap!({:ok, value})
        def unwrap!({:error, %SurrealDB.Error{} = error})

    (hgs_surrealdb_sdk 0.1.0) lib/mix/tasks/surreal/migration_task_helpers.ex:183: Mix.Tasks.Surreal.MigrationTaskHelpers.unwrap!/1
    (hgs_surrealdb_sdk 0.1.0) lib/mix/tasks/surreal.reset.ex:37: Mix.Tasks.Surreal.Reset.run/1
    (mix 1.20.1) lib/mix/task.ex:502: anonymous fn/3 in Mix.Task.run_task/5
    (mix 1.20.1) lib/mix/cli.ex:129: Mix.CLI.run_task/2
    /home/michael_intandem/.local/share/mise/installs/elixir/1.20.1/bin/mix:7: (file)
    (elixir 1.20.1) lib/code.ex:1639: Code.require_file/2
    ```
    


seed the database 


test mix surreal.load


surreal_db.create works, but when run the --namespace --database version it should output the required configuration block with the instructions on where it should normally be put.

create a mix command that reflects database structures and creates the zio schemas

remove "hgs" 

test all "mix surreal.*" commands

explore adding dashboards 
  full phoenix liveview or ??
  telemetry
explore making the sdk an mcp
