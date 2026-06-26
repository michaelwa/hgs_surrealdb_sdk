# Self-Contained SurrealDB Repo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `hgs_surrealdb_sdk` self-contained within the namespace/database from the host app's `config/config.exs` — move the migration registry into the app database (table `schema_migrations`), source migrations/seeds from a configured `repo_path`, and use single-file up/down migrations.

**Architecture:** The migration runner stops using a separate `sdk_meta/migration_registry` scope and runs all registry SQL against the configured client (the app's ns/db). Migration files carry `-- migrate:up` / `-- migrate:down` sections parsed by the runner. Mix tasks resolve a `repo_path` from store config (`<repo_path>/migrations`, `<repo_path>/seeds.exs`). Co-location makes `drop`/`reset` correct without registry-clearing logic.

**Tech Stack:** Elixir, SurrealDB HTTP `/sql`, Req (+ scripted test adapter), Igniter (installer), ExUnit.

**Spec:** `docs/superpowers/specs/2026-06-26-surreal-self-contained-repo-design.md`

## Global Constraints

- SDK version is `0.1.0` — this is a breaking change; **no backward-compat shims** (YAGNI).
- Registry table name is exactly `schema_migrations`.
- Registry lives in the **configured** client ns/db — never `sdk_meta`.
- Default `repo_path` is exactly `"priv/surreal_repo"`; migrations dir is `<repo_path>/migrations`; seeds file is `<repo_path>/seeds.exs`.
- Migration section markers: `-- migrate:up` (required) and `-- migrate:down` (optional). Match is line-based, case-insensitive, tolerant of leading whitespace and `>=2` leading dashes.
- Checksum is `"sha256:" <> sha256_hex(full_file_contents)` (unchanged formula, over the whole file).
- Removed surface: `sdk_meta`/`migration_registry` defaults, `registry_client/2`, `--registry-namespace`/`--registry-database`, `--down-path`, `target_ns`/`target_db` columns, `migration_key`, `MigrationTaskHelpers.clear_registry!/2`, `priv/surrealdb_migrations` default.
- Run the SDK suite from the repo root: `mix test`. Work happens in the `hgs_surrealdb_sdk` repo (`../../prototypes/hgs_surrealdb_sdk` relative to the test_igniter dogfood app).
- End-to-end verification always uses literal `--namespace X --database X` against a throwaway scope (e.g. `sdk_verify`); never run bare destructive tasks.

## File Structure

**Create:**
- `priv/schema_migrations/001_define_schema_migrations.surql` — new registry table schema.
- `lib/mix/tasks/surreal.seed.ex` — `mix surreal.seed`.

**Modify:**
- `lib/surreal_db/migrations.ex` — co-locate registry, rename table, parse up/down sections, rollback from same file.
- `lib/mix/tasks/surreal/migration_task_helpers.ex` — `repo_path` resolution; remove `clear_registry!`, `--down-path`, registry-scope options.
- `lib/mix/tasks/surreal.drop.ex`, `lib/mix/tasks/surreal.reset.ex` — remove `clear_registry!` calls.
- `lib/mix/tasks/surreal.rollback.ex` — down-section semantics (no `--down-path`).
- `lib/mix/tasks/surreal.gen.migration.ex` — scaffold up/down sections, write under `<repo_path>/migrations`.
- `lib/mix/tasks/surreal.ex` — help text (add `surreal.seed`).
- `lib/mix/tasks/hgs_surrealdb_sdk.install.ex` — write `repo_path`, scaffold `priv/surreal_repo/migrations` + `seeds.exs`, update notice.
- `test/surreal_db/migrations_test.exs`, `test/mix/tasks/surreal_migration_task_helpers_test.exs` — update assertions; add parser/repo_path tests.

**Delete:**
- `priv/surrealdb_migrations/sdk_registry/001_define_migration_registry.surql` (old registry schema).

---

### Task 1: Rename + relocate the registry schema to `schema_migrations`

**Files:**
- Create: `priv/schema_migrations/001_define_schema_migrations.surql`
- Delete: `priv/surrealdb_migrations/sdk_registry/001_define_migration_registry.surql`
- Modify: `lib/surreal_db/migrations.ex` (the `@registry_schema_path` module attribute near the top, currently `"surrealdb_migrations/sdk_registry/001_define_migration_registry.surql"`)
- Test: `test/surreal_db/migrations_test.exs` (the `install_registry` schema-body assertion)

**Interfaces:**
- Produces: registry schema file defining table `schema_migrations` with a unique index on `filename`; `@registry_schema_path` pointing at `"schema_migrations/001_define_schema_migrations.surql"`.

- [ ] **Step 1: Update the failing test for the new table name**

In `test/surreal_db/migrations_test.exs`, change the `install_registry` test body assertion:

```elixir
assert request.body =~ "DEFINE TABLE IF NOT EXISTS schema_migrations SCHEMAFULL"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/surreal_db/migrations_test.exs -k "install_registry"`
Expected: FAIL (body still says `sdk_migration`).

- [ ] **Step 3: Create the new schema file**

Create `priv/schema_migrations/001_define_schema_migrations.surql`:

```surql
-- SDK Migration Registry (co-located in the application database)
-- Tracks .surql migration files applied by the Elixir SDK.

DEFINE TABLE IF NOT EXISTS schema_migrations SCHEMAFULL;

DEFINE FIELD IF NOT EXISTS filename      ON TABLE schema_migrations TYPE string;
DEFINE FIELD IF NOT EXISTS checksum      ON TABLE schema_migrations TYPE string;
DEFINE FIELD IF NOT EXISTS sdk_version   ON TABLE schema_migrations TYPE option<string>;

DEFINE FIELD IF NOT EXISTS status ON TABLE schema_migrations TYPE string
  ASSERT $value IN ['running', 'applied', 'failed'];

DEFINE FIELD IF NOT EXISTS started_at    ON TABLE schema_migrations TYPE option<datetime>;
DEFINE FIELD IF NOT EXISTS finished_at   ON TABLE schema_migrations TYPE option<datetime>;
DEFINE FIELD IF NOT EXISTS applied_at    ON TABLE schema_migrations TYPE option<datetime>;
DEFINE FIELD IF NOT EXISTS duration_ms   ON TABLE schema_migrations TYPE option<int>;
DEFINE FIELD IF NOT EXISTS error_message ON TABLE schema_migrations TYPE option<string>;
DEFINE FIELD IF NOT EXISTS attempt_count ON TABLE schema_migrations TYPE int DEFAULT 1;
DEFINE FIELD IF NOT EXISTS created_at    ON TABLE schema_migrations TYPE datetime DEFAULT time::now();
DEFINE FIELD IF NOT EXISTS updated_at    ON TABLE schema_migrations TYPE datetime DEFAULT time::now();

DEFINE INDEX IF NOT EXISTS schema_migrations_filename
  ON TABLE schema_migrations FIELDS filename UNIQUE;

DEFINE INDEX IF NOT EXISTS schema_migrations_status
  ON TABLE schema_migrations FIELDS status;
```

- [ ] **Step 4: Point `@registry_schema_path` at the new file**

In `lib/surreal_db/migrations.ex`, change the attribute:

```elixir
@registry_schema_path "schema_migrations/001_define_schema_migrations.surql"
```

- [ ] **Step 5: Delete the old schema file**

```bash
git rm priv/surrealdb_migrations/sdk_registry/001_define_migration_registry.surql
```

- [ ] **Step 6: Run test to verify it passes**

Run: `mix test test/surreal_db/migrations_test.exs -k "install_registry"`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add priv/schema_migrations lib/surreal_db/migrations.ex test/surreal_db/migrations_test.exs
git commit -m "feat(migrations): rename registry table to schema_migrations"
```

---

### Task 2: Co-locate the registry and key on `filename`

Move every registry query off the separate scope and off `target_ns`/`target_db`/`migration_key`. The registry now runs against the configured client (the app's ns/db), keyed by `filename`.

**Files:**
- Modify: `lib/surreal_db/migrations.ex`
- Test: `test/surreal_db/migrations_test.exs`

**Interfaces:**
- Consumes: `@registry_schema_path` (Task 1).
- Produces:
  - `install_registry(client, opts)` runs the schema against `client` (no scope override).
  - `status/reset/rollback/run` no longer accept or use `registry_ns`/`registry_db`/`target_ns`/`target_db`.
  - Registry rows are uniquely identified by `filename`.
  - Public option keys after this task: `:path`, `:sdk_version`, `:step`, `:to`, `:to_exclusive`, `:steps`, `:allow_failed_rerun?` (the target/registry scope options are gone — scope comes from `client`).

- [ ] **Step 1: Update the `install_registry` scope test**

In `test/surreal_db/migrations_test.exs`, the existing `install_registry` test asserts the request targets `sdk_meta/migration_registry`. Change it to assert it targets the **client's** configured scope. If `client_with_adapter/1` builds a client with namespace `"test_ns"`/database `"test_db"` (check the helper at the bottom of the file and use its actual values), assert:

```elixir
assert Req.Request.get_header(request, "ns") == ["test_ns"]
assert Req.Request.get_header(request, "db") == ["test_db"]
```

Also update the `assert_registry_request/1` and `assert_target_request/1` private helpers so they assert the **same** (configured) scope — registry and target are now the same database. If both helpers become identical, keep both names (call sites read better) but give them the same body.

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/surreal_db/migrations_test.exs`
Expected: FAIL (current code sends registry SQL to `sdk_meta`).

- [ ] **Step 3: Remove the registry scope plumbing**

In `lib/surreal_db/migrations.ex`:

- Delete the module attributes `@default_registry_ns` and `@default_registry_db`.
- Delete the private function `registry_client/2`.
- Replace every `registry_client(client, opts)` call with `client`. (Call sites: `install_registry/2`, `run/2`, `status/2`, `reset/2`, `rollback/2`, and the rollback helpers — search the file for `registry_client`.)

- [ ] **Step 4: Drop target columns + `migration_key` from all registry SQL**

In `lib/surreal_db/migrations.ex`, rewrite the registry queries to remove `target_ns`/`target_db` filters and the `migration_key` field, keying on `filename`. Apply these exact bodies:

`status/2` query:

```elixir
query = """
SELECT filename, checksum, sdk_version, status, applied_at, started_at, finished_at, duration_ms, error_message, attempt_count
FROM schema_migrations
ORDER BY filename ASC;
"""
# call: SurrealDB.query(client, query)  (no variables)
```

`reset/2` query:

```elixir
query = "DELETE schema_migrations;"
# call: SurrealDB.query(client, query)
```

`lookup_registry_row/3` (preflight) query:

```elixir
query = """
SELECT id, filename, checksum, status, applied_at, error_message, attempt_count
FROM schema_migrations
WHERE filename = $filename
LIMIT 1;
"""
# variables: %{filename: migration.filename}
```

`mark_running/4` (`:new`) INSERT:

```elixir
query = """
INSERT INTO schema_migrations {
  filename: $filename,
  checksum: $checksum,
  sdk_version: $sdk_version,
  status: 'running',
  started_at: time::now(),
  finished_at: NONE,
  applied_at: NONE,
  duration_ms: NONE,
  error_message: NONE,
  attempt_count: 1,
  created_at: time::now(),
  updated_at: time::now()
};
"""
```

`mark_running/4` (`{:rerun_failed, _}`) UPDATE, `mark_applied/4`, and `mark_failed/5` UPDATEs: keep their `SET` clauses but change the table to `schema_migrations` and replace the WHERE with:

```elixir
WHERE filename = $filename
  AND checksum = $checksum
  AND status = 'running'
```

(`mark_running` rerun-failed uses `WHERE filename = $filename AND status = 'failed'`.)

Replace `registry_variables/2` with a filename-keyed builder:

```elixir
defp registry_variables(migration, config) do
  %{
    filename: migration.filename,
    checksum: migration.checksum,
    sdk_version: config.sdk_version
  }
end
```

Delete `target_variables/1`, the `migration_key/3` function, and any `target_ns`/`target_db` keys in `config` builders (`build_run_config`, `build_target_config`, `build_rollback_config`). These config builders should no longer `Keyword.fetch!` `:target_ns`/`:target_db`.

- [ ] **Step 5: Fix the `status`/`reset` callers**

`status/2` and `reset/2` currently build a target config to produce variables. Since there are no variables now, simplify: drop the `build_target_config` call where it only supplied `target_ns/target_db`. Keep `ensure_http_client(client)`. Example `reset/2`:

```elixir
def reset(%Client{} = client, _opts \\ []) do
  with :ok <- ensure_http_client(client) do
    SurrealDB.query(client, "DELETE schema_migrations;")
  end
end
```

- [ ] **Step 6: Run the suite**

Run: `mix test test/surreal_db/migrations_test.exs`
Expected: PASS. Update any remaining assertions in that file that still reference `target_ns`/`target_db`/`migration_key`/`sdk_migration` until green.

- [ ] **Step 7: Commit**

```bash
git add lib/surreal_db/migrations.ex test/surreal_db/migrations_test.exs
git commit -m "feat(migrations): co-locate registry in app db, key on filename"
```

---

### Task 3: Parse `-- migrate:up` / `-- migrate:down` sections

**Files:**
- Modify: `lib/surreal_db/migrations.ex` (`load_migrations/1` builds richer structs; add a parser)
- Test: `test/surreal_db/migrations_test.exs`

**Interfaces:**
- Consumes: file contents from disk.
- Produces:
  - Private `parse_migration(contents, filename) :: {:ok, %{up: String.t(), down: String.t() | nil}} | {:error, Error.t()}`.
  - `load_migrations/1` now yields maps `%{filename, path, up, down, checksum}` where `checksum` is over the full file contents and `down` is `nil` when no down section exists.
  - `execute_migration/5` runs `migration.up` (was `migration.contents`).

- [ ] **Step 1: Write failing parser tests**

Add to `test/surreal_db/migrations_test.exs` (these call the parser indirectly through `run`/`load`, or expose the parser — simplest is to test through `run`; if the parser is private, add a thin public `parse_migration/2` wrapper used only by tests, or test via a temp file + `run`). Use a directly testable public function `SurrealDB.Migrations.parse_migration/2`:

```elixir
describe "parse_migration/2" do
  test "splits up and down sections" do
    contents = """
    -- migrate:up
    DEFINE TABLE t SCHEMAFULL;

    -- migrate:down
    REMOVE TABLE t;
    """

    assert {:ok, %{up: up, down: down}} = Migrations.parse_migration(contents, "x.surql")
    assert up == "DEFINE TABLE t SCHEMAFULL;"
    assert down == "REMOVE TABLE t;"
  end

  test "down is nil when omitted" do
    assert {:ok, %{up: "CREATE a;", down: nil}} =
             Migrations.parse_migration("-- migrate:up\nCREATE a;\n", "x.surql")
  end

  test "missing up marker is an error" do
    assert {:error, %Error{type: :migration_parse_error}} =
             Migrations.parse_migration("CREATE a;", "x.surql")
  end

  test "markers are case-insensitive and whitespace-tolerant" do
    contents = "--   MIGRATE:UP \nCREATE a;\n--migrate:down\nDELETE a;"
    assert {:ok, %{up: "CREATE a;", down: "DELETE a;"}} =
             Migrations.parse_migration(contents, "x.surql")
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/surreal_db/migrations_test.exs -k "parse_migration"`
Expected: FAIL (`parse_migration/2` undefined).

- [ ] **Step 3: Implement the parser**

Add to `lib/surreal_db/migrations.ex`:

```elixir
@up_marker ~r/^\s*-{2,}\s*migrate:up\s*$/i
@down_marker ~r/^\s*-{2,}\s*migrate:down\s*$/i

@doc """
Splits a migration file into its `:up` and `:down` SurrealQL sections.

The `-- migrate:up` marker is required; `-- migrate:down` is optional and yields
`down: nil` when absent. Markers are case-insensitive and tolerate leading
whitespace and two-or-more dashes.
"""
@spec parse_migration(String.t(), String.t()) ::
        {:ok, %{up: String.t(), down: String.t() | nil}} | {:error, Error.t()}
def parse_migration(contents, filename) when is_binary(contents) do
  {sections, _current} =
    contents
    |> String.split(~r/\r?\n/)
    |> Enum.reduce({%{}, nil}, fn line, {acc, current} ->
      cond do
        Regex.match?(@up_marker, line) -> {Map.put_new(acc, :up, []), :up}
        Regex.match?(@down_marker, line) -> {Map.put_new(acc, :down, []), :down}
        is_nil(current) -> {acc, current}
        true -> {Map.update!(acc, current, &[line | &1]), current}
      end
    end)

  if Map.has_key?(sections, :up) do
    {:ok, %{up: join_section(sections, :up), down: nullify(join_section(sections, :down))}}
  else
    {:error,
     migration_error("migration is missing a `-- migrate:up` section",
       type: :migration_parse_error,
       details: %{filename: filename}
     )}
  end
end

defp join_section(sections, key) do
  sections |> Map.get(key, []) |> Enum.reverse() |> Enum.join("\n") |> String.trim()
end

defp nullify(""), do: nil
defp nullify(section), do: section
```

- [ ] **Step 4: Thread sections through `load_migrations/1`**

In the `load_migrations/1` clause that reads a file, replace the struct construction so it parses sections and keeps the full-file checksum:

```elixir
case File.read(full_path) do
  {:ok, contents} ->
    case parse_migration(contents, filename) do
      {:ok, %{up: up, down: down}} ->
        migration = %{
          filename: filename,
          path: full_path,
          up: up,
          down: down,
          checksum: checksum(contents)
        }

        {:cont, {:ok, [migration | acc]}}

      {:error, %Error{} = error} ->
        {:halt, {:error, error}}
    end

  {:error, reason} ->
    {:halt,
     {:error,
      migration_error("failed to read migration file",
        type: :migration_file_error,
        details: %{path: full_path, reason: reason}
      )}}
end
```

- [ ] **Step 5: Run `migration.up` in `execute_migration/5`**

In `execute_migration/5`, change the target query from `migration.contents` to `migration.up`:

```elixir
case SurrealDB.query(target, migration.up) do
```

- [ ] **Step 6: Run the suite**

Run: `mix test test/surreal_db/migrations_test.exs`
Expected: PASS. The `run` tests that script `CREATE first;` bodies must now wrap fixtures in `-- migrate:up\n...`. Update `tmp_migrations/1` fixtures in those tests accordingly (e.g. `"-- migrate:up\nCREATE first;"`), and update the scripted assertion `assert request.body == "CREATE first;"` to match the parsed up section (`"CREATE first;"`).

- [ ] **Step 7: Commit**

```bash
git add lib/surreal_db/migrations.ex test/surreal_db/migrations_test.exs
git commit -m "feat(migrations): parse up/down sections from single migration file"
```

---

### Task 4: Rollback runs the down section from the same file

**Files:**
- Modify: `lib/surreal_db/migrations.ex` (rollback path)
- Test: `test/surreal_db/migrations_test.exs`

**Interfaces:**
- Consumes: `load_migrations/1` structs with `:down` (Task 3); filename-keyed registry (Task 2).
- Produces: `rollback(client, opts) :: {:ok, [%{filename: String.t(), reverted?: boolean()}]} | {:error, Error.t()}`. `reverted?` is `true` when a `:down` section ran, `false` when the row was removed without a schema change (no down section).
- `rollback` opts: `:path` (migrations dir), `:steps`, `:to`, `:to_exclusive`. No `:down_path`.

- [ ] **Step 1: Write the failing rollback test**

```elixir
test "rollback runs the down section and reports reverted?" do
  path = tmp_migrations(%{
    "001_a.surql" => "-- migrate:up\nDEFINE TABLE a;\n-- migrate:down\nREMOVE TABLE a;"
  })

  calls =
    scripted_calls([
      # applied_rows lookup (registry, app scope)
      fn request ->
        assert_registry_request(request)
        assert request.body =~ "FROM schema_migrations"
        ok_response(request, [%{"filename" => "001_a.surql", "status" => "applied"}])
      end,
      # down section executed against target
      fn request ->
        assert_target_request(request)
        assert request.body == "REMOVE TABLE a;"
        ok_response(request, [nil])
      end,
      # delete rolled-back registry rows
      fn request ->
        assert_registry_request(request)
        assert request.body =~ "DELETE schema_migrations"
        ok_response(request, [])
      end
    ])

  client = client_with_adapter(scripted(calls))

  assert {:ok, [%{filename: "001_a.surql", reverted?: true}]} =
           Migrations.rollback(client, path: path, steps: 1)
end
```

(Use whatever scripted-adapter helper name the file already defines; `scripted/1` here is illustrative of the existing `scripted_calls` pattern.)

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/surreal_db/migrations_test.exs -k "rollback runs the down"`
Expected: FAIL.

- [ ] **Step 3: Rewrite the rollback path**

In `lib/surreal_db/migrations.ex`, replace the down-path-based rollback with one that loads migrations and runs their `:down` sections. Replace `rollback/2`, `applied_rows_for_rollback/2`, `execute_down_files/3`, `read_down_file/1`, and `delete_rolled_back_rows/3` with:

```elixir
def rollback(%Client{} = client, opts) when is_list(opts) do
  with :ok <- ensure_http_client(client),
       {:ok, config} <- build_rollback_config(opts),
       {:ok, migrations} <- load_migrations(config.path),
       {:ok, rows} <- applied_rows_for_rollback(client, config),
       {:ok, results} <- run_downs(client, migrations, rows),
       {:ok, _} <- delete_rolled_back_rows(client, rows) do
    {:ok, results}
  end
end

defp applied_rows_for_rollback(client, config) do
  query = """
  SELECT filename, checksum, status, applied_at
  FROM schema_migrations
  WHERE status = 'applied'
    #{rollback_version_filter(config)}
  ORDER BY filename DESC
  LIMIT #{config.steps};
  """

  with {:ok, %QueryResult{} = result} <- SurrealDB.query(client, query),
       {:ok, rows} <- first_statement_rows(result) do
    {:ok, rows}
  end
end

defp run_downs(client, migrations, rows) do
  by_filename = Map.new(migrations, &{&1.filename, &1})

  Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
    filename = Map.fetch!(row, "filename")

    case Map.get(by_filename, filename) do
      %{down: nil} ->
        {:cont, {:ok, [%{filename: filename, reverted?: false} | acc]}}

      %{down: down} when is_binary(down) ->
        case SurrealDB.query(client, down) do
          {:ok, _} -> {:cont, {:ok, [%{filename: filename, reverted?: true} | acc]}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end

      nil ->
        # Registry row with no matching file on disk: remove it but report not reverted.
        {:cont, {:ok, [%{filename: filename, reverted?: false} | acc]}}
    end
  end)
  |> case do
    {:ok, acc} -> {:ok, Enum.reverse(acc)}
    other -> other
  end
end

defp delete_rolled_back_rows(_client, []), do: {:ok, %QueryResult{results: []}}

defp delete_rolled_back_rows(client, rows) do
  filenames = Enum.map(rows, &Map.fetch!(&1, "filename"))

  query = """
  DELETE schema_migrations
  WHERE filename IN $filenames
    AND status = 'applied';
  """

  SurrealDB.query(client, query, %{filenames: filenames})
end
```

Note `run_downs/3` receives registry rows (string keys) and returns result maps; `delete_rolled_back_rows/2` takes the same registry rows. Keep `rollback_version_filter/1` as-is but ensure it references `filename` (it already does).

In `build_rollback_config/1`, drop `:down_path` and any `:target_ns`/`:target_db`; require `:path` and `:steps`, allow `:to`/`:to_exclusive`.

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/surreal_db/migrations_test.exs -k "rollback"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/surreal_db/migrations.ex test/surreal_db/migrations_test.exs
git commit -m "feat(migrations): rollback runs down section from migration file"
```

---

### Task 5: `repo_path` resolution in `MigrationTaskHelpers`

**Files:**
- Modify: `lib/mix/tasks/surreal/migration_task_helpers.ex`
- Test: `test/mix/tasks/surreal_migration_task_helpers_test.exs`

**Interfaces:**
- Consumes: store config (`store.config()` returns a keyword list that may contain `:repo_path`).
- Produces:
  - `repo_path(opts) :: String.t()` — resolves repo root: `--repo-path` > store config `:repo_path` > `"priv/surreal_repo"`.
  - `migration_paths(opts)` precedence: explicit `--migrations-path`/`--path` > `<repo_path>/migrations`.
  - `migration_opts/2` and `target_opts/2` no longer emit `:target_ns`/`:target_db`/`:registry_ns`/`:registry_db`/`:down_path`.
  - `clear_registry!/2` is **removed**.

- [ ] **Step 1: Write failing tests for path resolution**

Add to `test/mix/tasks/surreal_migration_task_helpers_test.exs`:

```elixir
alias Mix.Tasks.Surreal.MigrationTaskHelpers, as: Helpers

test "repo_path defaults to priv/surreal_repo" do
  assert Helpers.repo_path([]) == "priv/surreal_repo"
end

test "repo_path honors --repo-path override" do
  assert Helpers.repo_path(repo_path: "priv/custom") == "priv/custom"
end

test "migration_paths derives <repo_path>/migrations by default" do
  assert Helpers.migration_paths([]) == "priv/surreal_repo/migrations"
  assert Helpers.migration_paths(repo_path: "priv/custom") == "priv/custom/migrations"
end

test "explicit --path overrides repo-derived migrations dir" do
  assert Helpers.migration_paths(path: "priv/legacy") == "priv/legacy"
end
```

(If `repo_path`/`migration_paths` need store config to resolve, these tests pass `opts` that don't reference a store so the default branch is exercised. Store-config resolution is covered by the end-to-end run.)

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/mix/tasks/surreal_migration_task_helpers_test.exs`
Expected: FAIL.

- [ ] **Step 3: Add `:repo_path` to the option schema**

In `@switches`, add `repo_path: :string`. Remove `registry_namespace`, `registry_database`, and `down_path` from `@switches` (and any aliases referencing them).

- [ ] **Step 4: Implement `repo_path/1` and update `migration_paths/1`**

Add:

```elixir
@default_repo_path "priv/surreal_repo"

def repo_path(opts) do
  cond do
    present?(Keyword.get(opts, :repo_path)) -> Keyword.get(opts, :repo_path)
    present?(repo_path_from_store(opts)) -> repo_path_from_store(opts)
    true -> @default_repo_path
  end
end

defp repo_path_from_store(opts) do
  opts |> store_options() |> Keyword.get(:repo_path)
rescue
  _ -> nil
end
```

Replace `migration_paths/1` so it derives from `repo_path/1` when no explicit path is given:

```elixir
def migration_paths(opts) do
  explicit = Keyword.get_values(opts, :migrations_path) ++ Keyword.get_values(opts, :path)

  case explicit do
    [] -> Path.join(repo_path(opts), "migrations")
    [path] -> path
    paths -> paths
  end
end
```

- [ ] **Step 5: Trim `migration_opts/2` and `target_opts/2`; remove `clear_registry!/2`**

In `migration_opts/2`, drop `:target_ns`, `:target_db`, `:registry_ns`, `:registry_db`, `:down_path`. Keep `:path`, `:sdk_version`, and the optional `:allow_failed_rerun?`, `:step`, `:to`, `:to_exclusive`:

```elixir
def migration_opts(_client, opts) do
  [
    path: migration_paths(opts),
    sdk_version: Keyword.get(opts, :sdk_version, project_version())
  ]
  |> maybe_put(:allow_failed_rerun?, Keyword.get(opts, :allow_failed_rerun))
  |> maybe_put(:step, Keyword.get(opts, :step))
  |> maybe_put(:to, Keyword.get(opts, :to))
  |> maybe_put(:to_exclusive, Keyword.get(opts, :to_exclusive))
end
```

In `target_opts/2`, drop the target/registry scope and `:down_path`; keep `:path`, `:steps`, `:to`, `:to_exclusive`:

```elixir
def target_opts(_client, opts) do
  [path: migration_paths(opts)]
  |> maybe_put(:steps, rollback_steps(opts))
  |> maybe_put(:to, Keyword.get(opts, :to))
  |> maybe_put(:to_exclusive, Keyword.get(opts, :to_exclusive))
end
```

Delete the `clear_registry!/2` function and the `alias SurrealDB.Migrations` if it is now unused elsewhere in the module (keep it only if still referenced).

- [ ] **Step 6: Run to verify pass**

Run: `mix test test/mix/tasks/surreal_migration_task_helpers_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/mix/tasks/surreal/migration_task_helpers.ex test/mix/tasks/surreal_migration_task_helpers_test.exs
git commit -m "feat(tasks): resolve repo_path; drop registry/down-path options"
```

---

### Task 6: Simplify `drop`/`reset`/`rollback` tasks

**Files:**
- Modify: `lib/mix/tasks/surreal.drop.ex`, `lib/mix/tasks/surreal.reset.ex`, `lib/mix/tasks/surreal.rollback.ex`

**Interfaces:**
- Consumes: `Migrations.rollback/2` returning `[%{filename, reverted?}]` (Task 4); helpers without `clear_registry!` (Task 5).

- [ ] **Step 1: Remove `clear_registry!` from `surreal.drop`**

In `lib/mix/tasks/surreal.drop.ex`, delete the `Helpers.clear_registry!(client, opts)` call and the comment above it, and restore the messages (registry is dropped with the database):

```elixir
client = Helpers.build_client!(opts)
{namespace, database, existed?} = Helpers.drop_database!(client, opts)

if existed? do
  Mix.shell().info("Dropped SurrealDB database #{namespace}/#{database}.")
else
  Mix.shell().info("SurrealDB database #{namespace}/#{database} did not exist; nothing to drop.")
end
```

- [ ] **Step 2: Remove the registry-clear from `surreal.reset`**

In `lib/mix/tasks/surreal.reset.ex`, delete the `Helpers.clear_registry!(client, opts)` call and its `Mix.shell().info("Cleared migration registry ...")` line. (The `Migrations.run/2` call already installs the registry idempotently.) Keep drop → create → run.

- [ ] **Step 3: Rework `surreal.rollback` output for `reverted?`**

In `lib/mix/tasks/surreal.rollback.ex`, replace the body after building the client. Remove `down_path_given?/1`. Use the new return shape:

```elixir
results =
  client
  |> Migrations.rollback(Helpers.target_opts(client, opts))
  |> Helpers.unwrap!()

reverted = Enum.count(results, & &1.reverted?)
registry_only = Enum.reject(results, & &1.reverted?)

Mix.shell().info("Rolled back #{length(results)} migration(s); #{reverted} schema reversal(s) ran.")

Enum.each(results, fn r ->
  status = if r.reverted?, do: "reverted", else: "registry-only"
  Mix.shell().info("  #{status} #{r.filename}")
end)

if registry_only != [] do
  Mix.shell().error("""
  warning: #{length(registry_only)} migration(s) had no `-- migrate:down` section.
  Their registry rows were removed, but the schema was NOT changed. Add a
  `-- migrate:down` section to make them reversible, or use `mix surreal.reset`.
  """)
end
```

- [ ] **Step 4: Compile and smoke-test**

Run: `mix compile --warnings-as-errors`
Expected: clean compile (no references to `clear_registry!`, `down_path_given?`, `print_rows` if it became unused — remove `print_rows` from helpers only if no longer referenced anywhere).

- [ ] **Step 5: Commit**

```bash
git add lib/mix/tasks/surreal.drop.ex lib/mix/tasks/surreal.reset.ex lib/mix/tasks/surreal.rollback.ex
git commit -m "feat(tasks): simplify drop/reset; rollback reports reverted vs registry-only"
```

---

### Task 7: `gen.migration` scaffolds up/down under `repo_path`

**Files:**
- Modify: `lib/mix/tasks/surreal.gen.migration.ex`

**Interfaces:**
- Consumes: `Helpers.migration_paths/1` (Task 5), now repo-derived.

- [ ] **Step 1: Use repo-derived path + section template**

In `lib/mix/tasks/surreal.gen.migration.ex`, the `path` is already `Helpers.migration_path(opts)` — confirm `migration_path/1` returns the first of `migration_paths/1` (repo-derived). Change the file template to scaffold both sections:

```elixir
File.write!(full_path, """
-- #{name}

-- migrate:up


-- migrate:down

""")
```

- [ ] **Step 2: Manual verification**

Run from a host app (or temp dir with a store configured): `mix surreal.gen.migration add_widget`
Expected: creates `priv/surreal_repo/migrations/<ts>_add_widget.surql` containing `-- migrate:up` and `-- migrate:down`.

- [ ] **Step 3: Commit**

```bash
git add lib/mix/tasks/surreal.gen.migration.ex
git commit -m "feat(tasks): gen.migration scaffolds up/down sections under repo_path"
```

---

### Task 8: `mix surreal.seed`

**Files:**
- Create: `lib/mix/tasks/surreal.seed.ex`
- Modify: `lib/mix/tasks/surreal.ex` (help text)

**Interfaces:**
- Consumes: `Helpers.repo_path/1` (Task 5).
- Produces: `mix surreal.seed` evaluates `<repo_path>/seeds.exs` after `app.start`.

- [ ] **Step 1: Create the task**

Create `lib/mix/tasks/surreal.seed.ex`:

```elixir
defmodule Mix.Tasks.Surreal.Seed do
  @shortdoc "Runs the SurrealDB repo seed script"
  @moduledoc """
  Evaluates `<repo_path>/seeds.exs` (default `priv/surreal_repo/seeds.exs`) with the
  application started, so the store API is available.

      $ mix surreal.seed
      $ mix surreal.seed --repo-path priv/surreal_repo
  """

  use Mix.Task

  alias Mix.Tasks.Surreal.MigrationTaskHelpers, as: Helpers

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    opts = Helpers.parse!(argv)
    path = Path.join(Helpers.repo_path(opts), "seeds.exs")

    if File.exists?(path) do
      Mix.shell().info("Running seeds from #{path} ...")
      Code.eval_file(path)
      Mix.shell().info("Seeds complete.")
    else
      Mix.shell().info("No seed file at #{path}; nothing to seed.")
    end
  end
end
```

- [ ] **Step 2: Add it to the help listing**

In `lib/mix/tasks/surreal.ex`, add a line to the help block:

```
  mix surreal.seed                # Runs <repo_path>/seeds.exs
```

- [ ] **Step 3: Compile**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add lib/mix/tasks/surreal.seed.ex lib/mix/tasks/surreal.ex
git commit -m "feat(tasks): add surreal.seed running repo seeds.exs"
```

---

### Task 9: Igniter installer writes `repo_path` and scaffolds the repo folder

**Files:**
- Modify: `lib/mix/tasks/hgs_surrealdb_sdk.install.ex`

**Interfaces:**
- Consumes: nothing new.
- Produces: installed projects get a `repo_path` config key, a `priv/surreal_repo/migrations/.gitkeep`, and a `priv/surreal_repo/seeds.exs` template.

- [ ] **Step 1: Write the `repo_path` config + scaffolding**

In the `igniter/1` function (the `Code.ensure_loaded?(Igniter)` branch), after the existing `[store, :password]` config line, add a `repo_path` config line and create the repo files. Use Igniter's file creation API:

```elixir
|> Igniter.Project.Config.configure("config.exs", app, [store, :repo_path], "priv/surreal_repo")
|> Igniter.create_new_file("priv/surreal_repo/migrations/.gitkeep", "")
|> Igniter.create_new_file("priv/surreal_repo/seeds.exs", """
# Seed script for the SurrealDB store. Run with: mix surreal.seed
# The store API is available, e.g.:
#
#   #{inspect(store)}.create(MyApp.User, %{name: "Jane"})
""")
```

(If `Igniter.create_new_file/3` is not the exact name in the installed Igniter version, use the equivalent — check `Igniter` docs for creating a new source file; the key requirement is the two files exist after install.)

- [ ] **Step 2: Update the post-install notice**

Extend the `Igniter.add_notice(...)` text to mention the repo folder and tasks, e.g. append:

```
Migrations live in priv/surreal_repo/migrations (generate with
`mix surreal.gen.migration NAME`). Run them with `mix surreal.migrate`, and
seed data with `mix surreal.seed`. The migration registry table
(schema_migrations) is created inside your configured namespace/database.
```

- [ ] **Step 3: Verify the installer compiles**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add lib/mix/tasks/hgs_surrealdb_sdk.install.ex
git commit -m "feat(install): scaffold repo_path config, migrations dir, seeds.exs"
```

---

### Task 10: Full suite + end-to-end verification

**Files:** none (verification only).

- [ ] **Step 1: Run the full SDK suite**

Run: `mix test`
Expected: all green. Fix any remaining references to old names/columns surfaced here.

- [ ] **Step 2: End-to-end against a scratch scope (in the dogfood app)**

From the `test_igniter` app with the updated SDK vendored into `deps/` (mirror the changed files and `mix deps.compile hgs_surrealdb_sdk --force`), run, using **literal flags** (never bare):

```bash
mix surreal.gen.migration verify_profile --repo-path priv/surreal_repo
# edit the generated file: add up/down SurrealQL
mix surreal.setup    --namespace sdk_verify --database sdk_verify
mix surreal.migrate  --namespace sdk_verify --database sdk_verify   # skipped on rerun
mix surreal.migrations --namespace sdk_verify --database sdk_verify # row present
mix surreal.rollback --namespace sdk_verify --database sdk_verify --force  # reverted
mix surreal.reset    --namespace sdk_verify --database sdk_verify --force  # rebuilds
mix surreal.drop     --namespace sdk_verify --database sdk_verify --force  # db+registry gone
```

Expected: `schema_migrations` exists **inside** `sdk_verify/sdk_verify` (verify with `INFO FOR DB;` showing it in `tables`); `sdk_meta` is never created; rollback reverts schema when a down section exists.

- [ ] **Step 3: Commit any fixes**

```bash
git add -A
git commit -m "test: full suite + end-to-end verification for self-contained repo"
```

---

## Self-Review Notes (author)

- **Spec coverage:** §3 config → Task 5/9; §4 layout → Task 9; §5 registry → Task 1/2; §6 parser → Task 3; §7 task table → Task 6/7/8; §8 gen/seeds → Task 7/8; §9 installer → Task 9; §10 removals → Tasks 2/5/6; §11 testing → every task + Task 10.
- **Removed-surface audit:** `registry_client`/defaults (T2), target columns/`migration_key` (T2), `--down-path` (T4/T5), `clear_registry!` (T5/T6), `priv/surrealdb_migrations` default (T5), registry-scope options (T5).
- **Type consistency:** `Migrations.rollback/2` returns `[%{filename, reverted?}]` (defined T4, consumed T6); `parse_migration/2` returns `{:ok, %{up, down}}` (T3, consumed by `load_migrations`/`run_downs`); `repo_path/1` + `migration_paths/1` (T5, consumed T7/T8).
- **Open verification:** exact Igniter file-creation function name (Task 9 Step 1) must be confirmed against the installed Igniter version; behavior (two files created) is fixed.
