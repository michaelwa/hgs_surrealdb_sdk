defmodule SurrealDB.Migration.FileLoaderTest do
  use ExUnit.Case, async: true

  alias SurrealDB.Migration.FileLoader

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "surrealdb_migration_loader_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  test "loads only .surql files sorted by filename", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "002_second.surql"), "DEFINE TABLE second;")
    File.write!(Path.join(tmp_dir, "001_first.surql"), "DEFINE TABLE first;")
    File.write!(Path.join(tmp_dir, "README.md"), "ignore me")

    migrations = FileLoader.load!(tmp_dir)

    assert Enum.map(migrations, & &1.filename) == ["001_first.surql", "002_second.surql"]
    assert Enum.all?(migrations, &String.starts_with?(&1.checksum, "sha256:"))
    assert Enum.all?(migrations, &String.ends_with?(&1.path, &1.filename))
  end
end
