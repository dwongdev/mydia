defmodule Mydia.Library.FileOrganizer do
  @moduledoc """
  Handles organizing media files into category-based paths.

  This module provides functionality to:
  - Calculate destination paths for media items based on their category
  - Move/copy media files to category-appropriate paths
  - Reorganize entire libraries based on category configuration
  - Support dry-run mode for previewing changes

  ## Category Path Resolution

  When a library has `auto_organize: true` and `category_paths` configured,
  files are organized into category-specific subdirectories:

      /media/movies/
      ├── Anime/                    # anime_movie category
      │   └── Spirited Away (2001)/
      ├── Cartoons/                 # cartoon_movie category
      │   └── Toy Story (1995)/
      └── The Matrix (1999)/        # movie category (no special path)

  ## File Operations

  When moving files, the following priority is used:
  1. Hardlink (instant, no duplicate storage) - requires same filesystem
  2. Move (rename or copy+delete for cross-device)
  3. Copy (safest option, preserves original)

  ## Safety

  - Files are never deleted until copy is verified
  - Database is only updated after successful file operation
  - Dry-run mode shows changes without modifying anything
  """

  require Logger

  alias Mydia.Library.MediaFile
  alias Mydia.Media.MediaItem
  alias Mydia.Settings.LibraryPath
  alias Mydia.Repo

  @type organize_opts :: [
          dry_run: boolean(),
          use_hardlinks: boolean(),
          force_move: boolean()
        ]

  @type organize_result :: %{
          source: String.t(),
          destination: String.t(),
          action: :move | :copy | :hardlink | :skip | :error,
          reason: String.t() | nil
        }

  @type reorganize_result :: %{
          total: non_neg_integer(),
          moved: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer(),
          details: [organize_result()]
        }

  # Public API

  @doc """
  Determines the destination path for a media item based on its category.

  Uses the library's `category_paths` configuration to route the media
  to the appropriate subdirectory.

  ## Parameters

  - `media_item` - The media item to get the destination path for
  - `library_path` - The library path configuration

  ## Returns

  The absolute destination path for the media item's folder.

  ## Examples

      iex> media_item = %MediaItem{title: "Spirited Away", year: 2001, category: "anime_movie"}
      iex> library = %LibraryPath{path: "/movies", category_paths: %{"anime_movie" => "Anime"}, auto_organize: true}
      iex> FileOrganizer.destination_path(media_item, library)
      "/movies/Anime/Spirited Away (2001)"

      iex> media_item = %MediaItem{title: "The Matrix", year: 1999, category: "movie"}
      iex> library = %LibraryPath{path: "/movies", category_paths: %{}, auto_organize: false}
      iex> FileOrganizer.destination_path(media_item, library)
      "/movies/The Matrix (1999)"
  """
  @spec destination_path(MediaItem.t(), LibraryPath.t()) :: String.t()
  def destination_path(%MediaItem{} = media_item, %LibraryPath{} = library_path) do
    media_folder = build_media_folder(media_item)
    category = media_item.category

    LibraryPath.resolve_category_path(library_path, category, media_folder)
  end

  @doc """
  Moves a media file to its category-appropriate path.

  If the file is already in the correct location, it is skipped.
  The MediaFile record is updated with the new relative_path after a successful move.

  ## Options

  - `:dry_run` - If true, returns what would happen without making changes (default: false)
  - `:use_hardlinks` - If true, try hardlinks first on same filesystem (default: true)
  - `:force_move` - If true, move file even if hardlink fails (default: true)

  ## Returns

  - `{:ok, organize_result}` - Success with details of what happened
  - `{:error, reason}` - Operation failed

  ## Examples

      iex> FileOrganizer.organize_file(media_file, dry_run: true)
      {:ok, %{source: "/movies/Spirited Away (2001)/movie.mkv", destination: "/movies/Anime/Spirited Away (2001)/movie.mkv", action: :move, reason: nil}}
  """
  @spec organize_file(MediaFile.t(), organize_opts()) ::
          {:ok, organize_result()} | {:error, any()}
  def organize_file(%MediaFile{} = media_file, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)

    # Preload required associations
    media_file = preload_associations(media_file)

    with {:ok, media_item} <- get_media_item(media_file),
         {:ok, library_path} <- get_library_path(media_file),
         {:ok, source_path} <- get_source_path(media_file),
         {:ok, dest_path} <- calculate_destination(media_file, media_item, library_path) do
      if source_path == dest_path do
        {:ok,
         %{
           source: source_path,
           destination: dest_path,
           action: :skip,
           reason: "already in correct location"
         }}
      else
        if dry_run do
          {:ok,
           %{
             source: source_path,
             destination: dest_path,
             action: :move,
             reason: nil
           }}
        else
          do_organize_file(media_file, source_path, dest_path, library_path, opts)
        end
      end
    end
  end

  @doc """
  Re-organizes all files in a library based on current category configuration.

  This function:
  1. Finds all media files in the library
  2. Determines correct destination based on media item category
  3. Moves files that are not in the correct location

  ## Options

  - `:dry_run` - Preview changes without making them (default: false)
  - `:use_hardlinks` - Try hardlinks first for same-filesystem moves (default: true)
  - `:force_move` - Move file even if hardlink fails (default: true)

  ## Returns

  A summary of the reorganization with counts and details.

  ## Examples

      iex> FileOrganizer.reorganize_library(library_path, dry_run: true)
      {:ok, %{total: 100, moved: 25, skipped: 75, errors: 0, details: [...]}}
  """
  @spec reorganize_library(LibraryPath.t(), organize_opts()) ::
          {:ok, reorganize_result()} | {:error, any()}
  def reorganize_library(%LibraryPath{} = library_path, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)

    action = if dry_run, do: "previewing", else: "starting"

    Logger.info("Library reorganization #{action}",
      library_path_id: library_path.id,
      library_path: library_path.path,
      dry_run: dry_run
    )

    # Get all media files in this library
    media_files = list_library_media_files(library_path.id)

    results =
      media_files
      |> Task.async_stream(
        fn media_file -> organize_file(media_file, opts) end,
        max_concurrency: 4,
        timeout: 60_000
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:error, reason}
      end)

    summary = summarize_results(results)

    Logger.info("Library reorganization complete",
      library_path_id: library_path.id,
      total: summary.total,
      moved: summary.moved,
      skipped: summary.skipped,
      errors: summary.errors,
      dry_run: dry_run
    )

    {:ok, summary}
  end

  @doc """
  Calculates the destination path for a file without moving it.

  Useful for previewing where a file would be moved to.

  ## Returns

  - `{:ok, destination_path}` - The absolute path where the file would be placed
  - `{:error, reason}` - Could not calculate destination
  """
  @spec preview_destination(MediaFile.t()) :: {:ok, String.t()} | {:error, any()}
  def preview_destination(%MediaFile{} = media_file) do
    media_file = preload_associations(media_file)

    with {:ok, media_item} <- get_media_item(media_file),
         {:ok, library_path} <- get_library_path(media_file) do
      calculate_destination(media_file, media_item, library_path)
    end
  end

  # Private functions

  defp preload_associations(%MediaFile{} = media_file) do
    media_file
    |> Repo.preload([:library_path, :media_item, episode: :media_item])
  end

  defp get_media_item(%MediaFile{media_item: %MediaItem{} = media_item}), do: {:ok, media_item}

  defp get_media_item(%MediaFile{episode: %{media_item: %MediaItem{} = media_item}}),
    do: {:ok, media_item}

  defp get_media_item(_), do: {:error, :no_media_item}

  defp get_library_path(%MediaFile{library_path: %LibraryPath{} = library_path}),
    do: {:ok, library_path}

  defp get_library_path(_), do: {:error, :no_library_path}

  defp get_source_path(%MediaFile{} = media_file) do
    case MediaFile.absolute_path(media_file) do
      nil -> {:error, :no_source_path}
      path -> {:ok, path}
    end
  end

  defp calculate_destination(%MediaFile{} = media_file, %MediaItem{} = media_item, library_path) do
    # Get the filename from the current relative path
    filename = Path.basename(media_file.relative_path)

    # Get the destination folder based on category
    dest_folder = destination_path(media_item, library_path)

    # Build full destination path
    {:ok, Path.join(dest_folder, filename)}
  end

  defp do_organize_file(media_file, source_path, dest_path, library_path, opts) do
    use_hardlinks = Keyword.get(opts, :use_hardlinks, true)
    force_move = Keyword.get(opts, :force_move, true)

    # Ensure destination directory exists
    dest_dir = Path.dirname(dest_path)

    case File.mkdir_p(dest_dir) do
      :ok ->
        # Perform the file operation
        case move_or_copy_file(source_path, dest_path, use_hardlinks, force_move) do
          {:ok, action} ->
            # Update the database record
            new_relative_path = Path.relative_to(dest_path, library_path.path)

            case update_media_file_path(media_file, new_relative_path) do
              {:ok, _} ->
                # Clean up empty source directories
                cleanup_empty_directories(Path.dirname(source_path), library_path.path)

                {:ok,
                 %{
                   source: source_path,
                   destination: dest_path,
                   action: action,
                   reason: nil
                 }}

              {:error, reason} ->
                # Rollback: move file back
                File.rename(dest_path, source_path)

                {:ok,
                 %{
                   source: source_path,
                   destination: dest_path,
                   action: :error,
                   reason: "database update failed: #{inspect(reason)}"
                 }}
            end

          {:error, reason} ->
            {:ok,
             %{
               source: source_path,
               destination: dest_path,
               action: :error,
               reason: "file operation failed: #{inspect(reason)}"
             }}
        end

      {:error, reason} ->
        {:ok,
         %{
           source: source_path,
           destination: dest_path,
           action: :error,
           reason: "could not create destination directory: #{inspect(reason)}"
         }}
    end
  end

  defp move_or_copy_file(source, dest, use_hardlinks, force_move) do
    cond do
      # Try hardlink first if enabled and on same filesystem
      use_hardlinks && same_filesystem?(source, dest) ->
        case File.ln(source, dest) do
          :ok ->
            # Remove original file after successful hardlink
            File.rm(source)
            {:ok, :hardlink}

          {:error, _reason} when force_move ->
            # Fallback to move
            do_move_file(source, dest)

          {:error, reason} ->
            {:error, {:hardlink_failed, reason}}
        end

      # Move file
      force_move ->
        do_move_file(source, dest)

      # Copy only
      true ->
        case File.cp(source, dest) do
          :ok -> {:ok, :copy}
          {:error, reason} -> {:error, {:copy_failed, reason}}
        end
    end
  end

  defp do_move_file(source, dest) do
    case File.rename(source, dest) do
      :ok ->
        {:ok, :move}

      {:error, :exdev} ->
        # Cross-device move: copy then delete
        with :ok <- File.cp(source, dest),
             :ok <- File.rm(source) do
          {:ok, :move}
        else
          {:error, reason} -> {:error, {:cross_device_move_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:move_failed, reason}}
    end
  end

  defp same_filesystem?(path1, path2) do
    # path2 might not exist yet, so check its parent directory
    parent_path2 = Path.dirname(path2)

    with {:ok, %{major_device: dev1}} <- File.stat(path1),
         {:ok, %{major_device: dev2}} <- File.stat(parent_path2) do
      dev1 == dev2
    else
      _ -> false
    end
  end

  defp update_media_file_path(%MediaFile{} = media_file, new_relative_path) do
    media_file
    |> Ecto.Changeset.change(%{relative_path: new_relative_path})
    |> Repo.update()
  end

  defp cleanup_empty_directories(dir, library_root) do
    # Don't delete the library root itself
    if dir != library_root and String.starts_with?(dir, library_root) do
      case File.ls(dir) do
        {:ok, []} ->
          # Directory is empty, remove it
          File.rmdir(dir)
          # Recursively check parent
          cleanup_empty_directories(Path.dirname(dir), library_root)

        _ ->
          # Directory is not empty or couldn't be read, stop
          :ok
      end
    else
      :ok
    end
  end

  defp build_media_folder(%MediaItem{type: "movie", title: title, year: year}) do
    sanitize_filename(
      if year do
        "#{title} (#{year})"
      else
        title
      end
    )
  end

  defp build_media_folder(%MediaItem{type: "tv_show", title: title}) do
    sanitize_filename(title)
  end

  defp build_media_folder(%MediaItem{title: title}) do
    sanitize_filename(title)
  end

  defp sanitize_filename(filename) when is_binary(filename) do
    filename
    |> String.replace(~r/[<>:\"\/\\|?*]/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp sanitize_filename(_), do: "Unknown"

  defp list_library_media_files(library_path_id) do
    import Ecto.Query

    MediaFile
    |> where([mf], mf.library_path_id == ^library_path_id)
    |> Repo.all()
  end

  defp summarize_results(results) do
    initial = %{total: 0, moved: 0, skipped: 0, errors: 0, details: []}

    Enum.reduce(results, initial, fn result, acc ->
      case result do
        {:ok, %{action: :skip} = detail} ->
          %{acc | total: acc.total + 1, skipped: acc.skipped + 1, details: [detail | acc.details]}

        {:ok, %{action: action} = detail} when action in [:move, :hardlink, :copy] ->
          %{acc | total: acc.total + 1, moved: acc.moved + 1, details: [detail | acc.details]}

        {:ok, %{action: :error} = detail} ->
          %{acc | total: acc.total + 1, errors: acc.errors + 1, details: [detail | acc.details]}

        {:error, reason} ->
          detail = %{source: nil, destination: nil, action: :error, reason: inspect(reason)}
          %{acc | total: acc.total + 1, errors: acc.errors + 1, details: [detail | acc.details]}
      end
    end)
    |> Map.update!(:details, &Enum.reverse/1)
  end
end
