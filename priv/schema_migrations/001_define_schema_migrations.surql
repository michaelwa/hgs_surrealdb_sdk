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
