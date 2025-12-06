defmodule Mydia.Jobs.ThumbnailGeneration do
  @moduledoc """
  Background job for generating thumbnails and cover images from video files.

  This job processes media files to generate:
  - Cover thumbnails (static image from video)
  - Optionally sprite sheets and VTT files for scrubbing

  ## Features

  - Batch processing to avoid overwhelming the system
  - Progress tracking via PubSub for UI updates
  - Exponential backoff retry on failures
  - Support for single file, batch, and library-wide generation

  ## Usage

      # Generate for a single file
      Mydia.Jobs.ThumbnailGeneration.enqueue_file(media_file_id)

      # Generate for all files in a library path
      Mydia.Jobs.ThumbnailGeneration.enqueue_library(library_path_id)

      # Generate for all files missing thumbnails
      Mydia.Jobs.ThumbnailGeneration.enqueue_missing()

  ## Job Arguments

  - `media_file_id` - Generate thumbnail for a single file
  - `media_file_ids` - Generate thumbnails for a batch of files
  - `library_path_id` - Generate thumbnails for all files in a library
  - `mode` - Processing mode: "single", "batch", or "missing"
  - `include_sprites` - Also generate sprite sheets (default: false)
  """

  use Oban.Worker,
    queue: :media,
    max_attempts: 5,
    priority: 2

  require Logger

  import Ecto.Query

  alias Mydia.Library
  alias Mydia.Library.MediaFile
  alias Mydia.Library.ThumbnailGenerator
  alias Mydia.Library.SpriteGenerator
  alias Mydia.Repo

  @pubsub Mydia.PubSub
  @topic "thumbnail_generation"

  # Default batch size for processing multiple files
  @default_batch_size 10

  # Backoff schedule in seconds
  @backoff_schedule [30, 120, 300, 900, 1800]

  ## Public API

  @doc """
  Returns the PubSub topic for thumbnail generation progress.
  """
  def topic, do: @topic

  @doc """
  Subscribes the current process to thumbnail generation progress updates.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @doc """
  Enqueues a job to generate a thumbnail for a single media file.

  ## Options
    - `:include_sprites` - Also generate sprite sheet and VTT (default: false)
  """
  def enqueue_file(media_file_id, opts \\ []) when is_binary(media_file_id) do
    %{
      mode: "single",
      media_file_id: media_file_id,
      include_sprites: Keyword.get(opts, :include_sprites, false)
    }
    |> new()
    |> Oban.insert()
  end

  @doc """
  Enqueues a job to generate thumbnails for multiple media files.

  Files are processed in batches to avoid overwhelming the system.

  ## Options
    - `:include_sprites` - Also generate sprite sheets and VTT (default: false)
  """
  def enqueue_batch(media_file_ids, opts \\ []) when is_list(media_file_ids) do
    %{
      mode: "batch",
      media_file_ids: media_file_ids,
      include_sprites: Keyword.get(opts, :include_sprites, false)
    }
    |> new()
    |> Oban.insert()
  end

  @doc """
  Enqueues a job to generate thumbnails for all files in a library path.

  ## Options
    - `:include_sprites` - Also generate sprite sheets and VTT (default: false)
    - `:regenerate` - Regenerate even if thumbnails exist (default: false)
  """
  def enqueue_library(library_path_id, opts \\ []) when is_binary(library_path_id) do
    %{
      mode: "library",
      library_path_id: library_path_id,
      include_sprites: Keyword.get(opts, :include_sprites, false),
      regenerate: Keyword.get(opts, :regenerate, false)
    }
    |> new()
    |> Oban.insert()
  end

  @doc """
  Enqueues a job to generate thumbnails for all files missing them.

  ## Options
    - `:include_sprites` - Also generate sprite sheets and VTT (default: false)
    - `:library_type` - Only process files from this library type (optional)
  """
  def enqueue_missing(opts \\ []) do
    args = %{
      mode: "missing",
      include_sprites: Keyword.get(opts, :include_sprites, false)
    }

    args =
      case Keyword.get(opts, :library_type) do
        nil -> args
        type -> Map.put(args, :library_type, to_string(type))
      end

    args
    |> new()
    |> Oban.insert()
  end

  @doc """
  Cancels all pending thumbnail generation jobs.

  Returns the number of jobs cancelled.
  """
  def cancel_all do
    {count, _} =
      Oban.Job
      |> where([j], j.worker == ^inspect(__MODULE__))
      |> where([j], j.state in ["available", "scheduled", "retryable"])
      |> Repo.update_all(set: [state: "cancelled", cancelled_at: DateTime.utc_now()])

    broadcast_progress(%{event: :cancelled, count: count})
    {:ok, count}
  end

  ## Oban Worker Implementation

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "single", "media_file_id" => id} = args}) do
    include_sprites = Map.get(args, "include_sprites", false)

    case process_single_file(id, include_sprites) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{args: %{"mode" => "batch", "media_file_ids" => ids} = args}) do
    include_sprites = Map.get(args, "include_sprites", false)
    process_batch(ids, include_sprites)
  end

  def perform(%Oban.Job{args: %{"mode" => "library", "library_path_id" => id} = args}) do
    include_sprites = Map.get(args, "include_sprites", false)
    regenerate = Map.get(args, "regenerate", false)

    process_library(id, include_sprites, regenerate)
    :ok
  end

  def perform(%Oban.Job{args: %{"mode" => "missing"} = args}) do
    include_sprites = Map.get(args, "include_sprites", false)
    library_type = Map.get(args, "library_type")

    process_missing(include_sprites, library_type)
    :ok
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    index = min(attempt - 1, length(@backoff_schedule) - 1)
    Enum.at(@backoff_schedule, index)
  end

  ## Private Implementation

  defp process_single_file(media_file_id, include_sprites) do
    broadcast_progress(%{event: :started, total: 1, completed: 0})

    media_file =
      MediaFile
      |> Repo.get(media_file_id)
      |> Repo.preload(:library_path)

    result = generate_for_file(media_file, include_sprites)

    case result do
      {:ok, _} ->
        broadcast_progress(%{event: :completed, total: 1, completed: 1, failed: 0})
        {:ok, :completed}

      {:error, reason} ->
        broadcast_progress(%{event: :completed, total: 1, completed: 0, failed: 1})
        {:error, reason}
    end
  end

  defp process_batch(media_file_ids, include_sprites) do
    total = length(media_file_ids)
    broadcast_progress(%{event: :started, total: total, completed: 0})

    {completed, failed} =
      media_file_ids
      |> Enum.with_index(1)
      |> Enum.reduce({0, 0}, fn {id, index}, {completed, failed} ->
        media_file =
          MediaFile
          |> Repo.get(id)
          |> Repo.preload(:library_path)

        case generate_for_file(media_file, include_sprites) do
          {:ok, _} ->
            broadcast_progress(%{
              event: :progress,
              total: total,
              completed: completed + 1,
              current: index
            })

            {completed + 1, failed}

          {:error, reason} ->
            Logger.warning("Failed to generate thumbnail for #{id}: #{inspect(reason)}")
            {completed, failed + 1}
        end
      end)

    broadcast_progress(%{event: :completed, total: total, completed: completed, failed: failed})
    :ok
  end

  defp process_library(library_path_id, include_sprites, regenerate) do
    # Get all video files in the library
    query =
      from mf in MediaFile,
        where: mf.library_path_id == ^library_path_id,
        select: mf.id

    query =
      if regenerate do
        query
      else
        from mf in query, where: is_nil(mf.cover_blob)
      end

    file_ids = Repo.all(query)

    if file_ids == [] do
      broadcast_progress(%{event: :completed, total: 0, completed: 0, failed: 0})
      {:ok, :no_files}
    else
      # Process in batches
      process_in_batches(file_ids, include_sprites)
      {:ok, :completed}
    end
  end

  defp process_missing(include_sprites, library_type) do
    # Query files missing thumbnails
    query =
      from mf in MediaFile,
        join: lp in assoc(mf, :library_path),
        where: is_nil(mf.cover_blob),
        select: mf.id

    query =
      if library_type do
        type_atom = String.to_existing_atom(library_type)
        from [mf, lp] in query, where: lp.type == ^type_atom
      else
        query
      end

    file_ids = Repo.all(query)

    if file_ids == [] do
      broadcast_progress(%{event: :completed, total: 0, completed: 0, failed: 0})
      {:ok, :no_files}
    else
      process_in_batches(file_ids, include_sprites)
      {:ok, :completed}
    end
  end

  defp process_in_batches(file_ids, include_sprites) do
    total = length(file_ids)
    broadcast_progress(%{event: :started, total: total, completed: 0})

    {completed, failed} =
      file_ids
      |> Enum.chunk_every(@default_batch_size)
      |> Enum.with_index()
      |> Enum.reduce({0, 0}, fn {batch, batch_index}, {completed_acc, failed_acc} ->
        batch_start = batch_index * @default_batch_size

        {batch_completed, batch_failed} =
          batch
          |> Enum.with_index(batch_start + 1)
          |> Enum.reduce({0, 0}, fn {id, index}, {c, f} ->
            media_file =
              MediaFile
              |> Repo.get(id)
              |> Repo.preload(:library_path)

            case generate_for_file(media_file, include_sprites) do
              {:ok, _} ->
                broadcast_progress(%{
                  event: :progress,
                  total: total,
                  completed: completed_acc + c + 1,
                  current: index
                })

                {c + 1, f}

              {:error, reason} ->
                Logger.warning("Failed to generate thumbnail for #{id}: #{inspect(reason)}")
                {c, f + 1}
            end
          end)

        {completed_acc + batch_completed, failed_acc + batch_failed}
      end)

    broadcast_progress(%{event: :completed, total: total, completed: completed, failed: failed})
    {completed, failed}
  end

  defp generate_for_file(nil, _include_sprites) do
    {:error, :file_not_found}
  end

  defp generate_for_file(%MediaFile{} = media_file, include_sprites) do
    # Check if FFmpeg is available
    unless ThumbnailGenerator.ffmpeg_available?() do
      {:error, :ffmpeg_not_found}
    else
      # Generate cover thumbnail
      with {:ok, cover_checksum} <- ThumbnailGenerator.generate_cover(media_file) do
        # Update media file with cover checksum
        attrs = %{cover_blob: cover_checksum, generated_at: DateTime.utc_now()}

        attrs =
          if include_sprites do
            case SpriteGenerator.generate(media_file) do
              {:ok, %{sprite_checksum: sprite, vtt_checksum: vtt}} ->
                Map.merge(attrs, %{sprite_blob: sprite, vtt_blob: vtt})

              {:error, reason} ->
                Logger.warning(
                  "Failed to generate sprites for #{media_file.id}: #{inspect(reason)}"
                )

                attrs
            end
          else
            attrs
          end

        Library.update_media_file(media_file, attrs)
      end
    end
  end

  defp broadcast_progress(data) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:thumbnail_generation, data})
  end
end
