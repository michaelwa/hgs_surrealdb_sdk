defmodule SurrealDB.Migration.RegistryEntry do
  @moduledoc """
  Represents one persisted row in the SDK migration registry.
  """

  defstruct [
    :id,
    :migration_key,
    :target_ns,
    :target_db,
    :filename,
    :checksum,
    :sdk_version,
    :status,
    :applied_at,
    :started_at,
    :finished_at,
    :duration_ms,
    :error_message,
    :attempt_count
  ]

  @type status :: :pending | :running | :applied | :failed

  @type t :: %__MODULE__{
          id: term(),
          migration_key: String.t() | nil,
          target_ns: String.t() | nil,
          target_db: String.t() | nil,
          filename: String.t() | nil,
          checksum: String.t() | nil,
          sdk_version: String.t() | nil,
          status: status() | String.t() | nil,
          applied_at: term(),
          started_at: term(),
          finished_at: term(),
          duration_ms: non_neg_integer() | nil,
          error_message: String.t() | nil,
          attempt_count: non_neg_integer() | nil
        }
end
