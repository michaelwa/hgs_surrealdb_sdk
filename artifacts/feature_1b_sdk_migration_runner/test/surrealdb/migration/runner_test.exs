defmodule SurrealDB.Migration.RunnerTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Migration.Runner

  describe "run/2 option validation" do
    test "requires path target_ns target_db and sdk_version" do
      assert {:error, {:missing_required_options, missing}} = Runner.run(:client, [])

      assert :path in missing
      assert :target_ns in missing
      assert :target_db in missing
      assert :sdk_version in missing
    end
  end

  @tag :integration
  test "integration placeholder for full runner flow" do
    # CODEX_TODO:
    # Replace this placeholder with a real integration test once the SDK query API is wired.
    # Suggested test cases:
    # 1. install registry schema
    # 2. run one migration successfully
    # 3. rerun same file and assert skipped
    # 4. modify same filename contents and assert checksum drift
    # 5. force a bad migration and assert failed status + error_message
    assert true
  end
end
