defmodule Mydia.Downloads.JobManager do
  @moduledoc """
  GenServer to manage concurrent transcode jobs with queueing.

  This module manages FFmpeg MP4 transcoding jobs, limiting concurrent transcodes
  to prevent resource exhaustion and queueing pending jobs when at capacity.

  ## Features

  - **Concurrent job limiting**: Configurable max concurrent transcodes (default: 2)
  - **Automatic queueing**: Jobs are queued when at capacity and started when slots free up
  - **Job tracking**: Tracks active transcoder processes via Registry
  - **Graceful cancellation**: Cancels jobs and cleans up resources properly
  - **Status monitoring**: Get status of any job (queued, running, completed, failed)

  ## Registry

  Jobs are registered in `Mydia.Downloads.TranscodeRegistry` using a composite key:
  `{media_file_id, resolution}` to uniquely identify each transcode job.

  ## Usage

      # Start or queue a transcode job
      {:ok, pid} = JobManager.start_or_queue_job(
        media_file_id: "abc123",
        resolution: :p720,
        input_path: "/path/to/video.mkv",
        output_path: "/path/to/output.mp4",
        on_progress: fn progress -> IO.inspect(progress) end,
        on_complete: fn -> IO.puts("Done!") end,
        on_error: fn err -> IO.puts("Error: \#{err}") end
      )

      # Cancel a job (running or queued)
      :ok = JobManager.cancel_job("abc123", :p720)

      # Get job status
      {:ok, status} = JobManager.get_job_status("abc123", :p720)

      # List all active and queued jobs
      jobs = JobManager.list_active_jobs()
  """

  use GenServer
  require Logger

  alias Mydia.Downloads.FfmpegMp4Transcoder

  @registry_name Mydia.Downloads.TranscodeRegistry

  defmodule State do
    @moduledoc false
    defstruct max_concurrent: 2,
              active_jobs: %{},
              queued_jobs: :queue.new()

    @type job_key :: {media_file_id :: String.t(), resolution :: atom()}
    @type job_info :: %{
            pid: pid(),
            media_file_id: String.t(),
            resolution: atom(),
            started_at: DateTime.t()
          }
    @type queued_job :: %{
            job_key: job_key(),
            opts: keyword(),
            queued_at: DateTime.t()
          }

    @type t :: %__MODULE__{
            max_concurrent: pos_integer(),
            active_jobs: %{job_key() => job_info()},
            queued_jobs: :queue.queue(queued_job())
          }
  end

  ## Client API

  @doc """
  Starts the JobManager GenServer.

  ## Options

    * `:max_concurrent` - Maximum number of concurrent transcode jobs (default: 2)
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a transcode job or queues it if at capacity.

  ## Options

    * `:media_file_id` - (required) Unique identifier for the media file
    * `:resolution` - (required) Target resolution (`:p1080`, `:p720`, `:p480`)
    * `:input_path` - (required) Path to input video file
    * `:output_path` - (required) Path where output MP4 will be written
    * `:on_progress` - (optional) Progress callback function
    * `:on_complete` - (optional) Completion callback function
    * `:on_error` - (optional) Error callback function

  ## Returns

    * `{:ok, :queued}` - Job was queued (at capacity)
    * `{:ok, pid}` - Job started immediately
    * `{:error, :already_exists}` - Job already running or queued for this file/resolution
    * `{:error, reason}` - Job failed to start
  """
  def start_or_queue_job(opts) do
    media_file_id = Keyword.fetch!(opts, :media_file_id)
    resolution = Keyword.fetch!(opts, :resolution)

    GenServer.call(__MODULE__, {:start_or_queue_job, media_file_id, resolution, opts})
  end

  @doc """
  Cancels a running or queued transcode job.

  This will stop the FFmpeg process if running and clean up resources.

  ## Returns

    * `:ok` - Job cancelled or didn't exist
  """
  def cancel_job(media_file_id, resolution) do
    GenServer.call(__MODULE__, {:cancel_job, media_file_id, resolution})
  end

  @doc """
  Gets the status of a transcode job.

  ## Returns

    * `{:ok, :queued}` - Job is queued waiting for a slot
    * `{:ok, :running}` - Job is currently transcoding
    * `{:error, :not_found}` - No job found for this file/resolution
  """
  def get_job_status(media_file_id, resolution) do
    GenServer.call(__MODULE__, {:get_job_status, media_file_id, resolution})
  end

  @doc """
  Lists all active and queued transcode jobs.

  ## Returns

  A map with:
    * `:active` - List of active jobs with metadata
    * `:queued` - List of queued jobs with metadata
  """
  def list_active_jobs do
    GenServer.call(__MODULE__, :list_active_jobs)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    max_concurrent = Keyword.get(opts, :max_concurrent, 2)

    Logger.info("Starting JobManager with max_concurrent=#{max_concurrent}")

    state = %State{
      max_concurrent: max_concurrent,
      active_jobs: %{},
      queued_jobs: :queue.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:start_or_queue_job, media_file_id, resolution, opts}, _from, state) do
    job_key = job_key(media_file_id, resolution)

    cond do
      # Job already active
      Map.has_key?(state.active_jobs, job_key) ->
        {:reply, {:error, :already_exists}, state}

      # Job already queued
      job_queued?(state.queued_jobs, job_key) ->
        {:reply, {:error, :already_exists}, state}

      # At capacity, queue the job
      map_size(state.active_jobs) >= state.max_concurrent ->
        queued_job = %{
          job_key: job_key,
          opts: opts,
          queued_at: DateTime.utc_now()
        }

        state = %{state | queued_jobs: :queue.in(queued_job, state.queued_jobs)}

        Logger.info(
          "Job queued: #{media_file_id} @ #{resolution} (queue size: #{:queue.len(state.queued_jobs)})"
        )

        {:reply, {:ok, :queued}, state}

      # Start the job immediately
      true ->
        case start_transcode_job(media_file_id, resolution, opts) do
          {:ok, pid} ->
            # Monitor the transcoder process
            Process.monitor(pid)

            job_info = %{
              pid: pid,
              media_file_id: media_file_id,
              resolution: resolution,
              started_at: DateTime.utc_now()
            }

            state = %{state | active_jobs: Map.put(state.active_jobs, job_key, job_info)}

            Logger.info(
              "Job started: #{media_file_id} @ #{resolution} (active: #{map_size(state.active_jobs)}/#{state.max_concurrent})"
            )

            {:reply, {:ok, pid}, state}

          {:error, reason} = error ->
            Logger.error(
              "Failed to start job: #{media_file_id} @ #{resolution} - #{inspect(reason)}"
            )

            {:reply, error, state}
        end
    end
  end

  def handle_call({:cancel_job, media_file_id, resolution}, _from, state) do
    job_key = job_key(media_file_id, resolution)

    state =
      cond do
        # Cancel active job
        Map.has_key?(state.active_jobs, job_key) ->
          job_info = state.active_jobs[job_key]

          # Only try to stop if process is still alive
          if Process.alive?(job_info.pid) do
            try do
              FfmpegMp4Transcoder.stop_transcoding(job_info.pid)
            catch
              :exit, _ -> :ok
            end
          end

          # Clean up Registry entry
          Registry.unregister(@registry_name, job_key)

          Logger.info("Job cancelled: #{media_file_id} @ #{resolution}")

          %{state | active_jobs: Map.delete(state.active_jobs, job_key)}

        # Remove from queue
        job_queued?(state.queued_jobs, job_key) ->
          queued_jobs = remove_from_queue(state.queued_jobs, job_key)

          Logger.info("Job removed from queue: #{media_file_id} @ #{resolution}")

          %{state | queued_jobs: queued_jobs}

        # Job not found
        true ->
          state
      end

    {:reply, :ok, state}
  end

  def handle_call({:get_job_status, media_file_id, resolution}, _from, state) do
    job_key = job_key(media_file_id, resolution)

    status =
      cond do
        Map.has_key?(state.active_jobs, job_key) ->
          {:ok, :running}

        job_queued?(state.queued_jobs, job_key) ->
          {:ok, :queued}

        true ->
          {:error, :not_found}
      end

    {:reply, status, state}
  end

  def handle_call(:list_active_jobs, _from, state) do
    active =
      state.active_jobs
      |> Enum.map(fn {_key, info} ->
        %{
          media_file_id: info.media_file_id,
          resolution: info.resolution,
          started_at: info.started_at,
          status: :running
        }
      end)

    queued =
      state.queued_jobs
      |> :queue.to_list()
      |> Enum.map(fn job ->
        {media_file_id, resolution} = job.job_key

        %{
          media_file_id: media_file_id,
          resolution: resolution,
          queued_at: job.queued_at,
          status: :queued
        }
      end)

    result = %{
      active: active,
      queued: queued
    }

    {:reply, result, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # Find and remove the completed job
    job_entry =
      Enum.find(state.active_jobs, fn {_key, info} -> info.pid == pid end)

    state =
      case job_entry do
        {job_key, job_info} ->
          # Log completion/failure
          log_job_completion(job_info, reason)

          # Clean up Registry entry (registered to JobManager, not the transcoder)
          Registry.unregister(@registry_name, job_key)

          # Remove from active jobs
          state = %{state | active_jobs: Map.delete(state.active_jobs, job_key)}

          # Start next queued job if available
          start_next_queued_job(state)

        nil ->
          # Process not tracked (shouldn't happen)
          Logger.warning("Received DOWN for unknown process: #{inspect(pid)}")
          state
      end

    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Unhandled message in JobManager: #{inspect(msg)}")
    {:noreply, state}
  end

  ## Private Functions

  # Generate job key for tracking
  defp job_key(media_file_id, resolution), do: {media_file_id, resolution}

  # Check if a job is in the queue
  defp job_queued?(queue, job_key) do
    queue
    |> :queue.to_list()
    |> Enum.any?(fn job -> job.job_key == job_key end)
  end

  # Remove a job from the queue
  defp remove_from_queue(queue, job_key) do
    queue
    |> :queue.to_list()
    |> Enum.reject(fn job -> job.job_key == job_key end)
    |> :queue.from_list()
  end

  # Start a transcode job and register it
  defp start_transcode_job(media_file_id, resolution, opts) do
    job_key = job_key(media_file_id, resolution)

    # Check if already registered (shouldn't happen, but safety check)
    case Registry.lookup(@registry_name, job_key) do
      [] ->
        # Not registered, proceed

        # Start the transcoder
        case FfmpegMp4Transcoder.start_transcoding(opts) do
          {:ok, pid} ->
            # Unlink from the transcoder process - we use Process.monitor instead
            # to avoid crashing the JobManager when a transcoder exits abnormally
            Process.unlink(pid)

            # Register in the registry
            case Registry.register(@registry_name, job_key, %{
                   media_file_id: media_file_id,
                   resolution: resolution,
                   started_at: DateTime.utc_now()
                 }) do
              {:ok, _} ->
                {:ok, pid}

              {:error, {:already_registered, _existing_pid}} ->
                # Stop the transcoder we just started
                FfmpegMp4Transcoder.stop_transcoding(pid)
                {:error, :already_registered}
            end

          {:error, _reason} = error ->
            error
        end

      [{_pid, _value}] ->
        # Already registered
        {:error, :already_registered}
    end
  end

  # Start the next queued job if available
  defp start_next_queued_job(state) do
    case :queue.out(state.queued_jobs) do
      {{:value, queued_job}, remaining_queue} ->
        {media_file_id, resolution} = queued_job.job_key

        Logger.info(
          "Starting queued job: #{media_file_id} @ #{resolution} (queue size: #{:queue.len(remaining_queue)})"
        )

        # Try to start the job
        case start_transcode_job(media_file_id, resolution, queued_job.opts) do
          {:ok, pid} ->
            # Monitor the transcoder process
            Process.monitor(pid)

            job_info = %{
              pid: pid,
              media_file_id: media_file_id,
              resolution: resolution,
              started_at: DateTime.utc_now()
            }

            %{
              state
              | active_jobs: Map.put(state.active_jobs, queued_job.job_key, job_info),
                queued_jobs: remaining_queue
            }

          {:error, reason} ->
            Logger.error(
              "Failed to start queued job: #{media_file_id} @ #{resolution} - #{inspect(reason)}"
            )

            # Remove from queue and try next job
            %{state | queued_jobs: remaining_queue}
            |> start_next_queued_job()
        end

      {:empty, _} ->
        # No more queued jobs
        state
    end
  end

  # Log job completion or failure
  defp log_job_completion(job_info, reason) do
    case reason do
      :normal ->
        Logger.info("Job completed: #{job_info.media_file_id} @ #{job_info.resolution}")

      {:ffmpeg_failed, status} ->
        Logger.error(
          "Job failed: #{job_info.media_file_id} @ #{job_info.resolution} - FFmpeg exited with status #{status}"
        )

      other ->
        Logger.error(
          "Job terminated: #{job_info.media_file_id} @ #{job_info.resolution} - #{inspect(other)}"
        )
    end
  end
end
