defmodule Mydia.Repo.Migrations.CreateImportSessions do
  use Ecto.Migration

  def change do
    execute(
      """
      CREATE TABLE import_sessions (
        id TEXT PRIMARY KEY NOT NULL,
        user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        step TEXT NOT NULL CHECK(step IN ('select_path', 'review', 'importing', 'complete')),
        status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active', 'completed', 'expired', 'abandoned')),
        scan_path TEXT,
        session_data TEXT,
        scan_stats TEXT,
        import_progress TEXT,
        import_results TEXT,
        completed_at TEXT,
        expires_at TEXT,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """,
      "DROP TABLE IF EXISTS import_sessions"
    )

    create index(:import_sessions, [:user_id])
    create index(:import_sessions, [:status])
    create index(:import_sessions, [:expires_at])
  end
end
