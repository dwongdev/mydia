defmodule MydiaWeb.Api.DownloadController do
  use MydiaWeb, :controller

  require Logger

  alias Mydia.Library
  alias Mydia.Media
  alias Mydia.Downloads
  alias Mydia.Downloads.JobManager
  alias MydiaWeb.Api.RangeHelper

  @doc """
  GET /api/v1/download/:content_type/:id/options

  Returns available download quality options for a media file.

  ## Parameters
    - content_type: "movie" or "episode"
    - id: Media item ID (for movie) or Episode ID (for episode)

  ## Response
    {
      "options": [
        {"resolution": "1080p", "estimated_size": 5242880000},
        {"resolution": "720p", "estimated_size": 2621440000},
        {"resolution": "480p", "estimated_size": 1048576000}
      ]
    }
  """
  def options(conn, %{"content_type" => content_type, "id" => id}) do
    with {:ok, media_file} <- get_media_file(content_type, id) do
      # Get available quality options based on source file
      options = calculate_quality_options(media_file)

      conn
      |> put_status(:ok)
      |> json(%{options: options})
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Media not found"})

      {:error, :no_media_file} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "No media file available for download"})
    end
  end

  @doc """
  POST /api/v1/download/:content_type/:id/prepare

  Starts or returns existing transcode job for download.

  ## Parameters
    - content_type: "movie" or "episode"
    - id: Media item ID (for movie) or Episode ID (for episode)

  ## Body
    {"resolution": "720p"}

  ## Response
    {
      "job_id": "uuid",
      "status": "pending|transcoding|ready",
      "progress": 0.0
    }
  """
  def prepare(conn, %{"content_type" => content_type, "id" => id} = params) do
    resolution = params["resolution"] || "720p"

    with {:ok, media_file} <- get_media_file(content_type, id),
         {:ok, resolution} <- validate_resolution(resolution),
         {:ok, job} <- Downloads.get_or_create_job(media_file.id, resolution),
         :ok <- maybe_start_transcode(job, media_file) do
      conn
      |> put_status(:ok)
      |> json(%{
        job_id: job.id,
        status: job.status,
        progress: job.progress || 0.0
      })
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Media not found"})

      {:error, :no_media_file} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "No media file available for download"})

      {:error, :invalid_resolution} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid resolution. Must be one of: 1080p, 720p, 480p"})

      {:error, reason} ->
        Logger.error("Failed to prepare download: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to prepare download"})
    end
  end

  @doc """
  GET /api/v1/download/job/:job_id/status

  Returns current status and progress of a transcode job.

  ## Response
    {
      "job_id": "uuid",
      "status": "pending|transcoding|ready|failed",
      "progress": 0.75,
      "error": null
    }
  """
  def job_status(conn, %{"job_id" => job_id}) do
    case Mydia.Repo.get(Downloads.TranscodeJob, job_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Job not found"})

      job ->
        conn
        |> put_status(:ok)
        |> json(%{
          job_id: job.id,
          status: job.status,
          progress: job.progress || 0.0,
          error: job.error
        })
    end
  end

  @doc """
  DELETE /api/v1/download/job/:job_id

  Cancels a transcode job.

  ## Response
    {"status": "cancelled"}
  """
  def cancel_job(conn, %{"job_id" => job_id}) do
    case Mydia.Repo.get(Downloads.TranscodeJob, job_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Job not found"})

      job ->
        # Cancel the job in JobManager if it's running
        case Mydia.Repo.preload(job, :media_file) do
          %{media_file: media_file} when not is_nil(media_file) ->
            # Convert resolution string to atom for JobManager
            resolution_atom = resolution_to_atom(job.resolution)
            JobManager.cancel_job(media_file.id, resolution_atom)

            # Delete the job record
            Downloads.delete_job(job)

            conn
            |> put_status(:ok)
            |> json(%{status: "cancelled"})

          _ ->
            # Job has no media_file, just delete it
            Downloads.delete_job(job)

            conn
            |> put_status(:ok)
            |> json(%{status: "cancelled"})
        end
    end
  end

  @doc """
  GET /api/v1/download/job/:job_id/file

  Downloads the transcoded file with Range request support.

  Supports progressive download for files that are still being transcoded.
  """
  def download_file(conn, %{"job_id" => job_id}) do
    case Mydia.Repo.get(Downloads.TranscodeJob, job_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Job not found"})

      %{status: "pending"} = _job ->
        conn
        |> put_status(:accepted)
        |> json(%{error: "Transcode not started yet", status: "pending"})

      %{status: "transcoding", output_path: output_path} = job when not is_nil(output_path) ->
        # Transcoding in progress - allow progressive download
        serve_file_with_range(conn, job, output_path, transcoding: true)

      %{status: "transcoding"} = _job ->
        conn
        |> put_status(:accepted)
        |> json(%{error: "Transcode in progress, file not yet available", status: "transcoding"})

      %{status: "ready", output_path: output_path} = job when not is_nil(output_path) ->
        # Transcode complete - serve the file
        serve_file_with_range(conn, job, output_path, transcoding: false)

      %{status: "failed", error: error} = _job ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Transcode failed: #{error || "Unknown error"}"})

      _job ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "File not available"})
    end
  end

  ## Private Helpers

  # Get media file for a given content type and ID
  defp get_media_file("movie", media_item_id) do
    case Media.get_media_item!(media_item_id, preload: [:library_path]) do
      %{type: "movie"} = media_item ->
        # Get the first media file for this movie
        case Library.get_media_files_for_item(media_item.id, preload: [:library_path]) do
          [media_file | _] -> {:ok, media_file}
          [] -> {:error, :no_media_file}
        end

      _ ->
        {:error, :not_found}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp get_media_file("episode", episode_id) do
    case Media.get_episode!(episode_id) do
      episode ->
        # Get the first media file for this episode
        case Library.get_media_files_for_episode(episode.id, preload: [:library_path]) do
          [media_file | _] -> {:ok, media_file}
          [] -> {:error, :no_media_file}
        end
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp get_media_file(_content_type, _id), do: {:error, :not_found}

  # Calculate available quality options based on source file
  defp calculate_quality_options(media_file) do
    # Get source file size and resolution
    source_size = media_file.size || 0

    # Parse resolution to determine what qualities are available
    # Only offer qualities at or below the source resolution
    source_resolution = parse_resolution_height(media_file.resolution)

    available_resolutions =
      [
        {"1080p", 1080},
        {"720p", 720},
        {"480p", 480}
      ]
      |> Enum.filter(fn {_label, height} -> height <= source_resolution end)

    # Estimate file sizes based on bitrate reduction
    available_resolutions
    |> Enum.map(fn {resolution, height} ->
      estimated_size = estimate_file_size(source_size, source_resolution, height)
      %{resolution: resolution, estimated_size: estimated_size}
    end)
  end

  # Parse resolution string to height in pixels
  defp parse_resolution_height(nil), do: 1080
  defp parse_resolution_height("4K"), do: 2160
  defp parse_resolution_height("2160p"), do: 2160
  defp parse_resolution_height("1080p"), do: 1080
  defp parse_resolution_height("720p"), do: 720
  defp parse_resolution_height("480p"), do: 480

  defp parse_resolution_height(resolution) when is_binary(resolution) do
    # Try to extract number from string like "1920x1080"
    case Regex.run(~r/(\d+)x(\d+)/, resolution) do
      [_, _width, height] ->
        String.to_integer(height)

      _ ->
        # Default to 1080p if we can't parse
        1080
    end
  end

  defp parse_resolution_height(_), do: 1080

  # Estimate transcoded file size based on resolution scaling
  defp estimate_file_size(source_size, source_height, target_height)
       when source_height > 0 and target_height > 0 do
    # Rough estimate: file size scales quadratically with resolution
    # (due to both width and height scaling)
    ratio = target_height / source_height
    round(source_size * ratio * ratio)
  end

  defp estimate_file_size(source_size, _source_height, _target_height), do: source_size

  # Validate resolution parameter
  defp validate_resolution(resolution) when resolution in ["1080p", "720p", "480p"] do
    {:ok, resolution}
  end

  defp validate_resolution(_), do: {:error, :invalid_resolution}

  # Start transcode if job is pending
  defp maybe_start_transcode(%{status: "pending"} = job, media_file) do
    # Preload library_path if not already loaded
    media_file = Mydia.Repo.preload(media_file, :library_path)

    # Get absolute path to source file
    case Mydia.Library.MediaFile.absolute_path(media_file) do
      nil ->
        {:error, :source_file_not_found}

      input_path ->
        # Generate output path
        output_dir = Application.get_env(:mydia, :transcode_cache_dir, "/tmp/mydia/transcodes")
        File.mkdir_p!(output_dir)
        output_filename = "#{job.id}.mp4"
        output_path = Path.join(output_dir, output_filename)

        # Convert resolution string to atom for JobManager
        resolution_atom = resolution_to_atom(job.resolution)

        # Set up callbacks
        on_progress = fn progress ->
          Downloads.update_job_progress(job, progress)
        end

        on_complete = fn ->
          # Get final file size
          file_size =
            case File.stat(output_path) do
              {:ok, %{size: size}} -> size
              _ -> 0
            end

          Downloads.complete_job(job, output_path, file_size)
        end

        on_error = fn error ->
          Downloads.fail_job(job, inspect(error))
        end

        # Start the transcode job
        case JobManager.start_or_queue_job(
               media_file_id: media_file.id,
               resolution: resolution_atom,
               input_path: input_path,
               output_path: output_path,
               on_progress: on_progress,
               on_complete: on_complete,
               on_error: on_error
             ) do
          {:ok, _} -> :ok
          {:error, :already_exists} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Job already started or completed
  defp maybe_start_transcode(_job, _media_file), do: :ok

  # Convert resolution string to atom for JobManager
  defp resolution_to_atom("1080p"), do: :p1080
  defp resolution_to_atom("720p"), do: :p720
  defp resolution_to_atom("480p"), do: :p480
  defp resolution_to_atom(_), do: :p720

  # Serve file with Range request support
  defp serve_file_with_range(conn, job, file_path, opts) do
    transcoding = Keyword.get(opts, :transcoding, false)

    # Check if file exists
    case File.stat(file_path) do
      {:ok, %{size: file_size}} ->
        # Update last_accessed_at for LRU cache management
        Downloads.touch_last_accessed(job)

        # Get Range header
        range_header = get_req_header(conn, "range") |> List.first()

        case RangeHelper.parse_range_header(range_header, file_size) do
          {:ok, start, end_pos} ->
            # Partial content request
            {offset, length} = RangeHelper.calculate_range(start, end_pos)

            conn
            |> put_status(206)
            |> put_resp_content_type(RangeHelper.get_mime_type(file_path))
            |> put_resp_header("accept-ranges", "bytes")
            |> put_resp_header(
              "content-range",
              RangeHelper.format_content_range(start, end_pos, file_size)
            )
            |> put_resp_header("content-length", to_string(length))
            |> maybe_add_transcoding_header(transcoding)
            |> send_file(206, file_path, offset, length)

          :error ->
            # No range or invalid range - send entire file
            conn
            |> put_status(200)
            |> put_resp_content_type(RangeHelper.get_mime_type(file_path))
            |> put_resp_header("accept-ranges", "bytes")
            |> put_resp_header("content-length", to_string(file_size))
            |> maybe_add_transcoding_header(transcoding)
            |> send_file(200, file_path)
        end

      {:error, :enoent} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "File not found"})

      {:error, reason} ->
        Logger.error("Failed to stat file: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to access file"})
    end
  end

  # Add custom header to indicate file is still being transcoded
  defp maybe_add_transcoding_header(conn, true) do
    put_resp_header(conn, "x-transcode-status", "in-progress")
  end

  defp maybe_add_transcoding_header(conn, false), do: conn
end
