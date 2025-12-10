defmodule Mydia.Repo.Migrations.PopulateMediaFileRelativePaths do
  @moduledoc """
  One-time migration to populate library_path_id and relative_path for existing media files.

  This migration:
  1. Syncs runtime library paths to database
  2. Populates relative_path and library_path_id for all existing media files
  3. Logs orphaned files (files outside configured library paths)

  Note: A startup task (Mydia.Library.StartupSync) will handle ongoing synchronization
  and act as a safety net for edge cases.

  IMPORTANT: This migration uses schema-less queries to avoid depending on columns
  that may be added in future migrations.
  """

  use Ecto.Migration
  import Ecto.Query

  def up do
    # 1. Sync runtime library paths to database using schema-less queries
    # IMPORTANT: We cannot use LibraryPathSync here because it uses the compiled
    # LibraryPath schema which may include columns added in later migrations.
    synced_count = sync_library_paths_schemaless()

    IO.puts("""

    [Migration] Synced #{synced_count} runtime library paths to database
    """)

    # 2. Populate relative_path and library_path_id for all media files
    # Using schema-less queries to avoid depending on columns added in future migrations
    stats = populate_all_media_files()

    IO.puts("""
    [Migration] Populated relative paths for media files:
      - Updated: #{stats.updated}
      - Orphaned: #{stats.orphaned}
      - Failed: #{stats.failed}
    """)

    if stats.orphaned > 0 do
      IO.puts("""

      [Warning] Found #{stats.orphaned} orphaned files (no matching library path).
      These files are outside your configured library paths and will not be updated.
      Check the logs for details.
      """)
    end

    if stats.failed > 0 do
      IO.puts("""

      [Error] Failed to update #{stats.failed} files.
      Check the logs for details and consider running the migration again.
      """)
    end
  end

  def down do
    from("media_files")
    |> repo().update_all(set: [library_path_id: nil, relative_path: nil])

    IO.puts("""

    [Rollback] Cleared library_path_id and relative_path for all media files
    """)
  end

  # Schema-less implementation to avoid depending on MediaFile schema
  defp populate_all_media_files do
    # Get all library paths
    library_paths =
      from("library_paths", select: [:id, :path])
      |> repo().all()
      |> Enum.sort_by(fn lp -> -String.length(lp.path) end)

    # Get media files that need updating (missing library_path_id or relative_path)
    # Only select columns that exist at this migration point
    media_files =
      from(mf in "media_files",
        where: is_nil(mf.library_path_id) or is_nil(mf.relative_path),
        select: %{
          id: mf.id,
          path: mf.path,
          relative_path: mf.relative_path,
          library_path_id: mf.library_path_id
        }
      )
      |> repo().all()

    stats = %{updated: 0, orphaned: 0, failed: 0}

    Enum.reduce(media_files, stats, fn media_file, acc ->
      case populate_media_file(media_file, library_paths) do
        {:ok, :updated} -> %{acc | updated: acc.updated + 1}
        {:ok, :skipped} -> acc
        {:ok, :orphaned} -> %{acc | orphaned: acc.orphaned + 1}
        {:error, _} -> %{acc | failed: acc.failed + 1}
      end
    end)
  end

  defp populate_media_file(media_file, library_paths) do
    # Skip if already fully populated
    if media_file.library_path_id && media_file.relative_path do
      {:ok, :skipped}
    else
      file_path = media_file.path

      case find_matching_library_path(file_path, library_paths) do
        nil ->
          {:ok, :orphaned}

        library_path ->
          relative_path =
            media_file.relative_path || calculate_relative_path(file_path, library_path.path)

          from("media_files", where: [id: ^media_file.id])
          |> repo().update_all(
            set: [
              library_path_id: library_path.id,
              relative_path: relative_path
            ]
          )

          {:ok, :updated}
      end
    end
  rescue
    e -> {:error, e}
  end

  defp find_matching_library_path(nil, _library_paths), do: nil

  defp find_matching_library_path(file_path, library_paths) do
    # Library paths are already sorted by length descending (longest first)
    Enum.find(library_paths, fn library_path ->
      String.starts_with?(file_path, library_path.path)
    end)
  end

  defp calculate_relative_path(file_path, library_path) do
    file_path
    |> String.replace_prefix(library_path, "")
    |> String.trim_leading("/")
  end

  # Schema-less library path sync - only touches columns that exist at migration time
  defp sync_library_paths_schemaless do
    runtime_paths = get_runtime_library_paths()

    Enum.reduce(runtime_paths, 0, fn {path, type}, count ->
      # Check if path already exists (schema-less query)
      existing =
        from("library_paths",
          where: [path: ^path],
          select: [:id]
        )
        |> repo().one()

      if existing do
        # Already exists, skip
        count
      else
        # Insert new library path with only columns that exist at this migration point
        # Note: This migration runs after disabled and from_env columns are added
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        repo().insert_all("library_paths", [
          %{
            id: Ecto.UUID.generate(),
            path: path,
            type: Atom.to_string(type),
            monitored: true,
            from_env: true,
            disabled: false,
            inserted_at: now,
            updated_at: now
          }
        ])

        count + 1
      end
    end)
  end

  # Get library paths from runtime config (same logic as LibraryPathSync)
  defp get_runtime_library_paths do
    config = Application.get_env(:mydia, Mydia.Library, [])

    movie_paths =
      (config[:movie_paths] || [])
      |> Enum.map(&{&1, :movies})

    tv_paths =
      (config[:tv_paths] || [])
      |> Enum.map(&{&1, :series})

    movie_paths ++ tv_paths
  end
end
