defmodule SurrealDB.Migration.ChecksumTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Migration.Checksum

  describe "sha256/1" do
    test "returns a sha256-prefixed lowercase digest" do
      checksum = Checksum.sha256("DEFINE TABLE user;")

      assert String.starts_with?(checksum, "sha256:")
      assert String.length(checksum) == String.length("sha256:") + 64
      assert checksum == String.downcase(checksum)
    end

    test "is deterministic" do
      assert Checksum.sha256("abc") == Checksum.sha256("abc")
      assert Checksum.sha256("abc") != Checksum.sha256("abcd")
    end
  end

  describe "migration_key/3" do
    test "includes namespace database and filename in deterministic key" do
      key1 = Checksum.migration_key("ns", "db", "001_example.surql")
      key2 = Checksum.migration_key("ns", "db", "001_example.surql")
      key3 = Checksum.migration_key("other", "db", "001_example.surql")

      assert key1 == key2
      assert key1 != key3
      assert String.starts_with?(key1, "sha256:")
    end
  end
end
