-- Feature 1: Migration Runner Registry Query Reference
-- These queries are reference snippets. Codex should adapt them to the SDK's query API and variable binding conventions.

-- List migration state for a target namespace/database.
SELECT *
FROM sdk_migration
WHERE target_ns = $target_ns
  AND target_db = $target_db
ORDER BY filename ASC;

-- Preflight lookup for one migration file.
SELECT id, migration_key, target_ns, target_db, filename, checksum, status, applied_at, error_message, attempt_count
FROM sdk_migration
WHERE target_ns = $target_ns
  AND target_db = $target_db
  AND filename = $filename
LIMIT 1;

-- Detect checksum drift for an already-known migration filename.
SELECT id, filename, checksum AS stored_checksum, $checksum AS current_checksum, status
FROM sdk_migration
WHERE target_ns = $target_ns
  AND target_db = $target_db
  AND filename = $filename
  AND checksum != $checksum
LIMIT 1;

-- Mark a brand-new migration as running.
INSERT INTO sdk_migration CONTENT {
  migration_key: $migration_key,
  target_ns: $target_ns,
  target_db: $target_db,
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

-- Rerun a previously failed migration.
-- Important: do NOT insert a new row because unique index target_ns/target_db/filename would reject it.
UPDATE sdk_migration
SET
  status = 'running',
  started_at = time::now(),
  finished_at = NONE,
  applied_at = NONE,
  duration_ms = NONE,
  error_message = NONE,
  sdk_version = $sdk_version,
  checksum = $checksum,
  attempt_count += 1,
  updated_at = time::now()
WHERE target_ns = $target_ns
  AND target_db = $target_db
  AND filename = $filename
  AND status = 'failed';

-- Mark a running migration as applied.
UPDATE sdk_migration
SET
  status = 'applied',
  applied_at = time::now(),
  finished_at = time::now(),
  duration_ms = $duration_ms,
  error_message = NONE,
  sdk_version = $sdk_version,
  updated_at = time::now()
WHERE target_ns = $target_ns
  AND target_db = $target_db
  AND filename = $filename
  AND checksum = $checksum
  AND status = 'running';

-- Mark a running migration as failed.
UPDATE sdk_migration
SET
  status = 'failed',
  finished_at = time::now(),
  duration_ms = $duration_ms,
  error_message = $error_message,
  sdk_version = $sdk_version,
  updated_at = time::now()
WHERE target_ns = $target_ns
  AND target_db = $target_db
  AND filename = $filename
  AND checksum = $checksum
  AND status = 'running';
