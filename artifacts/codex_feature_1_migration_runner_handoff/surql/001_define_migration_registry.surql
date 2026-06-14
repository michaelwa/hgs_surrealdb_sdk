-- Feature 1: SDK Migration Runner Registry
-- Registry location recommendation:
--   namespace: sdk_meta
--   database:  migration_registry
--
-- This schema tracks .surql migration files applied by the Elixir SDK.

DEFINE TABLE IF NOT EXISTS sdk_migration SCHEMAFULL;

DEFINE FIELD IF NOT EXISTS migration_key ON TABLE sdk_migration TYPE string;
DEFINE FIELD IF NOT EXISTS target_ns ON TABLE sdk_migration TYPE string;
DEFINE FIELD IF NOT EXISTS target_db ON TABLE sdk_migration TYPE string;
DEFINE FIELD IF NOT EXISTS filename ON TABLE sdk_migration TYPE string;
DEFINE FIELD IF NOT EXISTS checksum ON TABLE sdk_migration TYPE string;
DEFINE FIELD IF NOT EXISTS sdk_version ON TABLE sdk_migration TYPE option<string>;

DEFINE FIELD IF NOT EXISTS status ON TABLE sdk_migration TYPE string
  ASSERT $value IN ['pending', 'running', 'applied', 'failed'];

DEFINE FIELD IF NOT EXISTS started_at ON TABLE sdk_migration TYPE option<datetime>;
DEFINE FIELD IF NOT EXISTS finished_at ON TABLE sdk_migration TYPE option<datetime>;
DEFINE FIELD IF NOT EXISTS applied_at ON TABLE sdk_migration TYPE option<datetime>;
DEFINE FIELD IF NOT EXISTS duration_ms ON TABLE sdk_migration TYPE option<int>;
DEFINE FIELD IF NOT EXISTS error_message ON TABLE sdk_migration TYPE option<string>;
DEFINE FIELD IF NOT EXISTS attempt_count ON TABLE sdk_migration TYPE int DEFAULT 1;
DEFINE FIELD IF NOT EXISTS created_at ON TABLE sdk_migration TYPE datetime DEFAULT time::now();
DEFINE FIELD IF NOT EXISTS updated_at ON TABLE sdk_migration TYPE datetime DEFAULT time::now();

-- Rerun protection: one migration filename per target namespace/database.
DEFINE INDEX IF NOT EXISTS sdk_migration_unique_file
  ON TABLE sdk_migration
  FIELDS target_ns, target_db, filename
  UNIQUE;

-- Deterministic SDK lookup key.
DEFINE INDEX IF NOT EXISTS sdk_migration_unique_key
  ON TABLE sdk_migration
  FIELDS migration_key
  UNIQUE;

-- Efficient status listing per target database.
DEFINE INDEX IF NOT EXISTS sdk_migration_target_status
  ON TABLE sdk_migration
  FIELDS target_ns, target_db, status;

-- Useful for drift/debug lookup.
DEFINE INDEX IF NOT EXISTS sdk_migration_checksum
  ON TABLE sdk_migration
  FIELDS checksum;
