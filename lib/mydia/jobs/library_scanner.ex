defmodule Mydia.Jobs.LibraryScanner do
  @moduledoc """
  Background job for scanning the media library.

  This job:
  - Scans configured library paths for media files
  - Detects new, modified, and deleted files
  - Updates the database with file information
  - Tracks scan status and errors
  """

  use Oban.Worker,
    queue: :media,
    max_attempts: 3

  require Logger
  alias Mydia.{Library, Settings, Repo, Metadata}
  alias Mydia.Library.{MetadataMatcher, MetadataEnricher, FileParser, FileAnalyzer}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    library_path_id = Map.get(args, "library_path_id")

    case library_path_id do
      nil ->
        scan_all_libraries()

      id ->
        scan_single_library(id)
    end
  end

  ## Private Functions

  defp scan_all_libraries do
    Logger.info("Starting scan of all monitored library paths")

    library_paths = Settings.list_library_paths()
    monitored_paths = Enum.filter(library_paths, & &1.monitored)

    Logger.info("Found #{length(monitored_paths)} monitored library paths")

    results =
      Enum.map(monitored_paths, fn library_path ->
        scan_library_path(library_path)
      end)

    successful = Enum.count(results, &match?({:ok, _}, &1))
    failed = Enum.count(results, &match?({:error, _}, &1))

    Logger.info("Library scan completed",
      total: length(results),
      successful: successful,
      failed: failed
    )

    :ok
  end

  defp scan_single_library(library_path_id) do
    Logger.info("Starting scan of library path", library_path_id: library_path_id)

    library_path = Settings.get_library_path!(library_path_id)

    case scan_library_path(library_path) do
      {:ok, result} ->
        Logger.info("Library scan completed successfully",
          library_path_id: library_path_id,
          new_files: length(result.changes.new_files),
          modified_files: length(result.changes.modified_files),
          deleted_files: length(result.changes.deleted_files)
        )

        :ok

      {:error, reason} ->
        Logger.error("Library scan failed",
          library_path_id: library_path_id,
          reason: reason
        )

        {:error, reason}
    end
  end

  defp scan_library_path(library_path) do
    Logger.debug("Scanning library path",
      id: library_path.id,
      path: library_path.path,
      type: library_path.type
    )

    # Broadcast scan started
    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      "library_scanner",
      {:library_scan_started, %{library_path_id: library_path.id, type: library_path.type}}
    )

    # Mark scan as in progress (skip for runtime paths)
    if updatable_library_path?(library_path) do
      {:ok, _} =
        Settings.update_library_path(library_path, %{
          last_scan_status: :in_progress,
          last_scan_error: nil
        })
    end

    # Perform the file system scan
    progress_callback = fn count ->
      Logger.debug("Scan progress", library_path_id: library_path.id, files_scanned: count)
    end

    scan_result =
      case Library.Scanner.scan(library_path.path, progress_callback: progress_callback) do
        {:ok, result} -> result
        {:error, reason} -> raise "Scan failed: #{inspect(reason)}"
      end

    # Get existing files from database - only files within this library path
    # This prevents deleting files from other library paths during scan
    existing_files = Library.list_media_files(path_prefix: library_path.path)

    # Detect changes
    changes = Library.Scanner.detect_changes(scan_result, existing_files)

    # Process changes in a transaction (file operations only, no metadata enrichment)
    transaction_result =
      Repo.transaction(fn ->
        # Add new files (without metadata enrichment)
        new_media_files =
          Enum.map(changes.new_files, fn file_info ->
            case Library.create_scanned_media_file(%{
                   path: file_info.path,
                   size: file_info.size,
                   verified_at: DateTime.utc_now()
                 }) do
              {:ok, media_file} ->
                Logger.debug("Added new media file", path: file_info.path)
                {:ok, media_file, file_info}

              {:error, changeset} ->
                Logger.error("Failed to create media file",
                  path: file_info.path,
                  errors: inspect(changeset.errors)
                )

                {:error, file_info}
            end
          end)

        # Update modified files
        Enum.each(changes.modified_files, fn file_info ->
          case Library.get_media_file_by_path(file_info.path) do
            nil ->
              Logger.warning("Modified file not found in database", path: file_info.path)

            media_file ->
              {:ok, _} =
                Library.update_media_file(media_file, %{
                  size: file_info.size,
                  verified_at: DateTime.utc_now()
                })

              Logger.debug("Updated media file", path: file_info.path)
          end
        end)

        # Mark deleted files
        Enum.each(changes.deleted_files, fn media_file ->
          {:ok, _} = Library.delete_media_file(media_file)
          Logger.debug("Deleted media file record", path: media_file.path)
        end)

        %{changes: changes, scan_result: scan_result, new_media_files: new_media_files}
      end)

    # After transaction commits, enrich new files with metadata (outside transaction)
    case transaction_result do
      {:ok, result} ->
        # Get metadata provider config
        metadata_config = Metadata.default_relay_config()

        # Process metadata enrichment for new files (outside transaction)
        Enum.each(result.new_media_files, fn
          {:ok, media_file, file_info} ->
            # Try to parse, match, and enrich the file
            process_media_file(media_file, file_info, metadata_config)

          {:error, _file_info} ->
            :ok
        end)

        # Also re-enrich orphaned files (files without media_item_id or episode_id)
        orphaned_files =
          existing_files
          |> Enum.filter(fn file ->
            is_nil(file.media_item_id) and is_nil(file.episode_id)
          end)

        if orphaned_files != [] do
          Logger.info("Re-enriching orphaned files", count: length(orphaned_files))

          Enum.each(orphaned_files, fn media_file ->
            # Find the file in scan_result to get file_info
            file_info =
              Enum.find(result.scan_result.files, fn f -> f.path == media_file.path end)

            if file_info do
              Logger.debug("Re-enriching orphaned file", path: media_file.path)
              process_media_file(media_file, file_info, metadata_config)
            end
          end)
        end

        {:ok, result}

      error ->
        error
    end
    |> case do
      {:ok, result} ->
        # Update library path with success status (skip for runtime paths)
        if updatable_library_path?(library_path) do
          {:ok, _} =
            Settings.update_library_path(library_path, %{
              last_scan_at: DateTime.utc_now(),
              last_scan_status: :success,
              last_scan_error: nil
            })
        end

        # Broadcast scan completed
        Phoenix.PubSub.broadcast(
          Mydia.PubSub,
          "library_scanner",
          {:library_scan_completed,
           %{
             library_path_id: library_path.id,
             type: library_path.type,
             new_files: length(result.changes.new_files),
             modified_files: length(result.changes.modified_files),
             deleted_files: length(result.changes.deleted_files)
           }}
        )

        {:ok, result}

      {:error, reason} ->
        error_message = "Transaction failed: #{inspect(reason)}"

        # Update library path with error status (skip for runtime paths)
        if updatable_library_path?(library_path) do
          {:ok, _} =
            Settings.update_library_path(library_path, %{
              last_scan_at: DateTime.utc_now(),
              last_scan_status: :failed,
              last_scan_error: error_message
            })
        end

        # Broadcast scan failed
        Phoenix.PubSub.broadcast(
          Mydia.PubSub,
          "library_scanner",
          {:library_scan_failed,
           %{library_path_id: library_path.id, type: library_path.type, error: error_message}}
        )

        {:error, reason}
    end
  rescue
    error ->
      error_message = Exception.format(:error, error, __STACKTRACE__)
      Logger.error("Library scan raised exception", error: error_message)

      # Update library path with error status (skip for runtime paths)
      if updatable_library_path?(library_path) do
        {:ok, _} =
          Settings.update_library_path(library_path, %{
            last_scan_at: DateTime.utc_now(),
            last_scan_status: :failed,
            last_scan_error: error_message
          })
      end

      # Broadcast scan failed
      Phoenix.PubSub.broadcast(
        Mydia.PubSub,
        "library_scanner",
        {:library_scan_failed,
         %{library_path_id: library_path.id, type: library_path.type, error: error_message}}
      )

      {:error, error}
  end

  # Checks if a library path can be updated in the database.
  # Runtime library paths (from environment variables) can't be updated.
  defp updatable_library_path?(%{id: id}) when is_binary(id) do
    !String.starts_with?(id, "runtime::")
  end

  defp updatable_library_path?(_), do: true

  defp process_media_file(media_file, file_info, metadata_config) do
    Logger.debug("Processing media file for metadata", path: file_info.path)

    # Try to match the file to metadata
    case MetadataMatcher.match_file(file_info.path, config: metadata_config) do
      {:ok, match_result} ->
        Logger.info("Matched media file",
          path: file_info.path,
          title: match_result.title,
          provider_id: match_result.provider_id,
          confidence: match_result.match_confidence
        )

        # Enrich with full metadata
        case MetadataEnricher.enrich(match_result,
               config: metadata_config,
               media_file_id: media_file.id
             ) do
          {:ok, media_item} ->
            Logger.info("Enriched media item",
              media_item_id: media_item.id,
              title: media_item.title
            )

            # Extract technical file metadata (resolution, codec, bitrate, etc.)
            extract_and_update_file_metadata(media_file, file_info)

          {:error, reason} ->
            Logger.warning("Failed to enrich media",
              path: file_info.path,
              reason: reason
            )
        end

      {:error, :unknown_media_type} ->
        Logger.debug("Could not determine media type",
          path: file_info.path
        )

      {:error, :no_matches_found} ->
        Logger.warning("No metadata matches found",
          path: file_info.path
        )

      {:error, :low_confidence_match} ->
        Logger.warning("Only low confidence matches found",
          path: file_info.path
        )

      {:error, reason} ->
        Logger.warning("Failed to match media file",
          path: file_info.path,
          reason: reason
        )
    end
  rescue
    error ->
      Logger.error("Exception while processing media file",
        path: file_info.path,
        error: Exception.message(error)
      )
  end

  # Extract technical metadata from file and update the media_file record
  defp extract_and_update_file_metadata(media_file, file_info) do
    # Parse filename for fallback metadata
    filename_metadata = FileParser.parse(Path.basename(file_info.path))

    # Extract technical metadata from the actual file using FFprobe
    file_metadata =
      case FileAnalyzer.analyze(file_info.path) do
        {:ok, metadata} ->
          Logger.debug("Extracted file metadata via FFprobe",
            path: file_info.path,
            resolution: metadata.resolution,
            codec: metadata.codec
          )

          metadata

        {:error, reason} ->
          Logger.debug("Failed to analyze file with FFprobe, using filename metadata only",
            path: file_info.path,
            reason: reason
          )

          # Continue with empty metadata - we'll use filename fallback below
          %{
            resolution: nil,
            codec: nil,
            audio_codec: nil,
            bitrate: nil,
            hdr_format: nil
          }
      end

    # Merge metadata: prefer actual file metadata, fall back to filename parsing
    update_attrs = %{
      resolution: file_metadata.resolution || filename_metadata.quality.resolution,
      codec: file_metadata.codec || filename_metadata.quality.codec,
      audio_codec: file_metadata.audio_codec || filename_metadata.quality.audio,
      bitrate: file_metadata.bitrate,
      hdr_format: file_metadata.hdr_format || filename_metadata.quality.hdr_format
    }

    case Library.update_media_file(media_file, update_attrs) do
      {:ok, updated_file} ->
        Logger.debug("Updated file with technical metadata",
          path: file_info.path,
          resolution: updated_file.resolution,
          codec: updated_file.codec
        )

        :ok

      {:error, changeset} ->
        Logger.warning("Failed to update file with technical metadata",
          path: file_info.path,
          errors: inspect(changeset.errors)
        )

        :error
    end
  rescue
    error ->
      Logger.error("Exception while extracting file metadata",
        path: file_info.path,
        error: Exception.message(error)
      )

      :error
  end
end
