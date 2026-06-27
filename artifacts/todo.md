seed the database

test mix surreal.load

create the migration table in the local database not in sdk_meta

---
we are in an elixir phoenix application. it is being used for testing the the hgs_surrealdb_sdk igniter instation, and verifying the functionality contained within applications that are consuming this dependency.
---

organizations/tenants
projects
applications

surreal_db.create works, but when run the --namespace --database version it should output the required configuration block with the instructions on where it should normally be put.

create a mix command that reflects database structures then creates the zio schemas

remove "hgs" 

test all "mix surreal.*" commands

explore adding dashboards 
  full phoenix liveview or ??
  telemetry
explore making the sdk an mcp
