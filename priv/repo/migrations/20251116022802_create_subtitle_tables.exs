defmodule Mydia.Repo.Migrations.CreateSubtitleTables do
  use Ecto.Migration

  def change do
    # Subtitles table: stores downloaded subtitle metadata and file paths
    # Tracks which subtitles are already downloaded and their properties
    execute(
      """
      CREATE TABLE subtitles (
        id TEXT PRIMARY KEY NOT NULL,
        media_file_id TEXT NOT NULL REFERENCES media_files(id) ON DELETE CASCADE,
        language TEXT NOT NULL,
        provider TEXT NOT NULL,
        subtitle_hash TEXT NOT NULL UNIQUE,
        file_path TEXT NOT NULL,
        sync_offset INTEGER DEFAULT 0,
        format TEXT NOT NULL,
        rating REAL,
        download_count INTEGER,
        hearing_impaired INTEGER NOT NULL DEFAULT 0 CHECK(hearing_impaired IN (0, 1)),
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """,
      "DROP TABLE IF EXISTS subtitles"
    )

    create index(:subtitles, [:media_file_id])
    create index(:subtitles, [:language])

    # Media hashes table: stores OpenSubtitles moviehash for each media file
    # Enables fast hash-based subtitle matching
    execute(
      """
      CREATE TABLE media_hashes (
        media_file_id TEXT PRIMARY KEY NOT NULL REFERENCES media_files(id) ON DELETE CASCADE,
        opensubtitles_hash TEXT NOT NULL,
        file_size INTEGER NOT NULL,
        calculated_at TEXT NOT NULL
      )
      """,
      "DROP TABLE IF EXISTS media_hashes"
    )

    create index(:media_hashes, [:opensubtitles_hash])
  end
end
