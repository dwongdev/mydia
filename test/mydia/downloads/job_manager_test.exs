defmodule Mydia.Downloads.JobManagerTest do
  use ExUnit.Case, async: false

  alias Mydia.Downloads.JobManager

  # We need a supervised GenServer for these tests
  setup do
    # The Registry is already started by the Application supervision tree
    # The JobManager is also already started

    # Cancel all existing jobs to start fresh
    %{active: active, queued: queued} = JobManager.list_active_jobs()

    Enum.each(active, fn job ->
      JobManager.cancel_job(job.media_file_id, job.resolution)
    end)

    Enum.each(queued, fn job ->
      JobManager.cancel_job(job.media_file_id, job.resolution)
    end)

    # Wait for cleanup and Registry to fully clear
    Process.sleep(200)

    # Ensure Registry is completely clean before starting tests
    registry_name = Mydia.Downloads.TranscodeRegistry
    all_entries = Registry.select(registry_name, [{{:"$1", :"$2", :"$3"}, [], [:"$$"]}])

    if all_entries != [] do
      # Force unregister any stale entries (shouldn't happen but safety)
      Enum.each(all_entries, fn [_key, pid, _value] ->
        if Process.alive?(pid) do
          # Process still alive, stop it
          GenServer.stop(pid, :normal)
          Process.sleep(50)
        end
      end)

      # Wait a bit more for Registry auto-cleanup
      Process.sleep(100)
    end

    :ok
  end

  describe "start_or_queue_job/1" do
    test "starts a job immediately when under capacity" do
      # Create an actual minimal test video for this test
      input_path = create_minimal_test_video()
      output_path = create_temp_output_path()

      test_pid = self()

      # Use a simple callback to signal job started
      result =
        JobManager.start_or_queue_job(
          media_file_id: "file1",
          resolution: :p720,
          input_path: input_path,
          output_path: output_path,
          on_progress: fn _progress -> send(test_pid, :progress_called) end
        )

      assert {:ok, pid} = result
      assert is_pid(pid)

      # Verify job status is running
      assert {:ok, :running} = JobManager.get_job_status("file1", :p720)

      # Clean up
      JobManager.cancel_job("file1", :p720)

      # Wait for job to actually stop
      Process.sleep(100)

      # Clean up test files
      File.rm(input_path)
      if File.exists?(output_path), do: File.rm(output_path)
    end

    test "queues jobs when at capacity" do
      test_pid = self()

      # Start 2 jobs (at capacity)
      {:ok, pid1} =
        JobManager.start_or_queue_job(
          media_file_id: "file1",
          resolution: :p720,
          input_path: create_test_video(),
          output_path: create_temp_output_path(),
          on_complete: fn -> send(test_pid, {:completed, "file1"}) end
        )

      {:ok, pid2} =
        JobManager.start_or_queue_job(
          media_file_id: "file2",
          resolution: :p720,
          input_path: create_test_video(),
          output_path: create_temp_output_path(),
          on_complete: fn -> send(test_pid, {:completed, "file2"}) end
        )

      assert is_pid(pid1)
      assert is_pid(pid2)

      # Third job should be queued
      {:ok, :queued} =
        JobManager.start_or_queue_job(
          media_file_id: "file3",
          resolution: :p720,
          input_path: create_test_video(),
          output_path: create_temp_output_path(),
          on_complete: fn -> send(test_pid, {:completed, "file3"}) end
        )

      # Verify statuses
      assert {:ok, :running} = JobManager.get_job_status("file1", :p720)
      assert {:ok, :running} = JobManager.get_job_status("file2", :p720)
      assert {:ok, :queued} = JobManager.get_job_status("file3", :p720)

      # Clean up
      JobManager.cancel_job("file1", :p720)
      JobManager.cancel_job("file2", :p720)
      JobManager.cancel_job("file3", :p720)
    end

    test "rejects duplicate jobs for same file and resolution" do
      # Start first job
      {:ok, _pid} =
        JobManager.start_or_queue_job(
          media_file_id: "file1",
          resolution: :p720,
          input_path: create_test_video(),
          output_path: create_temp_output_path()
        )

      # Try to start duplicate job
      result =
        JobManager.start_or_queue_job(
          media_file_id: "file1",
          resolution: :p720,
          input_path: create_test_video(),
          output_path: create_temp_output_path()
        )

      assert {:error, :already_exists} = result

      # Clean up
      JobManager.cancel_job("file1", :p720)
    end

    test "allows same file with different resolutions" do
      # Start job for 720p
      {:ok, _pid1} =
        JobManager.start_or_queue_job(
          media_file_id: "file1",
          resolution: :p720,
          input_path: create_test_video(),
          output_path: create_temp_output_path()
        )

      # Start job for 480p (should succeed)
      result =
        JobManager.start_or_queue_job(
          media_file_id: "file1",
          resolution: :p480,
          input_path: create_test_video(),
          output_path: create_temp_output_path()
        )

      assert {:ok, _pid2} = result

      # Clean up
      JobManager.cancel_job("file1", :p720)
      JobManager.cancel_job("file1", :p480)
    end
  end

  describe "cancel_job/2" do
    test "cancels a running job" do
      # Start a job
      {:ok, pid} =
        JobManager.start_or_queue_job(
          media_file_id: "file1",
          resolution: :p720,
          input_path: create_test_video(),
          output_path: create_temp_output_path()
        )

      assert Process.alive?(pid)

      # Cancel the job
      :ok = JobManager.cancel_job("file1", :p720)

      # Wait for process to terminate
      Process.sleep(100)

      # Job should no longer be found
      assert {:error, :not_found} = JobManager.get_job_status("file1", :p720)
    end

    test "removes a queued job" do
      # Fill capacity
      {:ok, _pid1} =
        JobManager.start_or_queue_job(
          media_file_id: "file1",
          resolution: :p720,
          input_path: create_test_video(),
          output_path: create_temp_output_path()
        )

      {:ok, _pid2} =
        JobManager.start_or_queue_job(
          media_file_id: "file2",
          resolution: :p720,
          input_path: create_test_video(),
          output_path: create_temp_output_path()
        )

      # Queue a third job
      {:ok, :queued} =
        JobManager.start_or_queue_job(
          media_file_id: "file3",
          resolution: :p720,
          input_path: create_test_video(),
          output_path: create_temp_output_path()
        )

      assert {:ok, :queued} = JobManager.get_job_status("file3", :p720)

      # Cancel the queued job
      :ok = JobManager.cancel_job("file3", :p720)

      # Job should no longer be found
      assert {:error, :not_found} = JobManager.get_job_status("file3", :p720)

      # Clean up
      JobManager.cancel_job("file1", :p720)
      JobManager.cancel_job("file2", :p720)
    end

    test "returns :ok when cancelling non-existent job" do
      result = JobManager.cancel_job("nonexistent", :p720)
      assert :ok = result
    end
  end

  describe "get_job_status/2" do
    test "returns :running for active jobs" do
      {:ok, _pid} =
        JobManager.start_or_queue_job(
          media_file_id: "file1",
          resolution: :p720,
          input_path: create_test_video(),
          output_path: create_temp_output_path()
        )

      assert {:ok, :running} = JobManager.get_job_status("file1", :p720)

      JobManager.cancel_job("file1", :p720)
    end

    test "returns :queued for queued jobs" do
      # Fill capacity
      {:ok, _pid1} =
        JobManager.start_or_queue_job(
          media_file_id: "file1",
          resolution: :p720,
          input_path: create_test_video(),
          output_path: create_temp_output_path()
        )

      {:ok, _pid2} =
        JobManager.start_or_queue_job(
          media_file_id: "file2",
          resolution: :p720,
          input_path: create_test_video(),
          output_path: create_temp_output_path()
        )

      # Queue a job
      {:ok, :queued} =
        JobManager.start_or_queue_job(
          media_file_id: "file3",
          resolution: :p720,
          input_path: create_test_video(),
          output_path: create_temp_output_path()
        )

      assert {:ok, :queued} = JobManager.get_job_status("file3", :p720)

      # Clean up
      JobManager.cancel_job("file1", :p720)
      JobManager.cancel_job("file2", :p720)
      JobManager.cancel_job("file3", :p720)
    end

    test "returns :not_found for non-existent jobs" do
      assert {:error, :not_found} = JobManager.get_job_status("nonexistent", :p720)
    end
  end

  describe "list_active_jobs/0" do
    test "lists active and queued jobs" do
      # Start jobs
      {:ok, _pid1} =
        JobManager.start_or_queue_job(
          media_file_id: "file1",
          resolution: :p720,
          input_path: create_test_video(),
          output_path: create_temp_output_path()
        )

      {:ok, _pid2} =
        JobManager.start_or_queue_job(
          media_file_id: "file2",
          resolution: :p480,
          input_path: create_test_video(),
          output_path: create_temp_output_path()
        )

      # Queue a job
      {:ok, :queued} =
        JobManager.start_or_queue_job(
          media_file_id: "file3",
          resolution: :p720,
          input_path: create_test_video(),
          output_path: create_temp_output_path()
        )

      result = JobManager.list_active_jobs()

      assert %{active: active, queued: queued} = result
      assert length(active) == 2
      assert length(queued) == 1

      # Verify active jobs
      assert Enum.any?(active, fn job ->
               job.media_file_id == "file1" && job.resolution == :p720 && job.status == :running
             end)

      assert Enum.any?(active, fn job ->
               job.media_file_id == "file2" && job.resolution == :p480 && job.status == :running
             end)

      # Verify queued job
      assert Enum.any?(queued, fn job ->
               job.media_file_id == "file3" && job.resolution == :p720 && job.status == :queued
             end)

      # Clean up
      JobManager.cancel_job("file1", :p720)
      JobManager.cancel_job("file2", :p480)
      JobManager.cancel_job("file3", :p720)
    end

    test "returns empty lists when no jobs" do
      result = JobManager.list_active_jobs()

      assert %{active: [], queued: []} = result
    end
  end

  describe "automatic queue processing" do
    @tag :slow
    test "automatically starts queued jobs when slots become available" do
      test_pid = self()

      # Create very short test videos that transcode quickly
      input1 = create_minimal_test_video()
      input2 = create_minimal_test_video()
      input3 = create_minimal_test_video()

      # Start 2 jobs (at capacity)
      {:ok, _pid1} =
        JobManager.start_or_queue_job(
          media_file_id: "file1",
          resolution: :p720,
          input_path: input1,
          output_path: create_temp_output_path(),
          on_complete: fn -> send(test_pid, {:completed, "file1"}) end
        )

      {:ok, _pid2} =
        JobManager.start_or_queue_job(
          media_file_id: "file2",
          resolution: :p720,
          input_path: input2,
          output_path: create_temp_output_path(),
          on_complete: fn -> send(test_pid, {:completed, "file2"}) end
        )

      # Queue a third job
      {:ok, :queued} =
        JobManager.start_or_queue_job(
          media_file_id: "file3",
          resolution: :p720,
          input_path: input3,
          output_path: create_temp_output_path(),
          on_complete: fn -> send(test_pid, {:completed, "file3"}) end
        )

      # Third job should be queued
      assert {:ok, :queued} = JobManager.get_job_status("file3", :p720)

      # Wait for one of the first jobs to complete
      assert_receive {:completed, completed_id}, 10_000
      assert completed_id in ["file1", "file2"]

      # Give the manager a moment to process the queue
      Process.sleep(200)

      # Third job should now be running (or completed if it was very fast)
      status = JobManager.get_job_status("file3", :p720)
      assert status == {:ok, :running} or status == {:error, :not_found}

      # Clean up (files that might still be running)
      JobManager.cancel_job("file1", :p720)
      JobManager.cancel_job("file2", :p720)
      JobManager.cancel_job("file3", :p720)

      # Clean up test files
      File.rm(input1)
      File.rm(input2)
      File.rm(input3)
    end
  end

  # Helper functions

  defp create_test_video do
    # Create a simple test video file path (doesn't need to exist for most tests)
    # For tests that actually run FFmpeg, use create_minimal_test_video/0
    "/tmp/test_video_#{System.unique_integer([:positive])}.mp4"
  end

  defp create_minimal_test_video do
    # Create a minimal 1-second test video for actual transcoding tests
    output_path = "/tmp/test_video_#{System.unique_integer([:positive])}.mp4"

    # Use FFmpeg to create a 1-second test video
    # This is a solid color video with no audio, very quick to create and transcode
    System.cmd("ffmpeg", [
      "-f",
      "lavfi",
      "-i",
      "color=c=blue:s=320x240:d=1",
      "-f",
      "lavfi",
      "-i",
      "anullsrc=r=48000:cl=stereo",
      "-t",
      "1",
      "-c:v",
      "libx264",
      "-preset",
      "ultrafast",
      "-c:a",
      "aac",
      "-y",
      output_path
    ])

    output_path
  end

  defp create_temp_output_path do
    "/tmp/test_output_#{System.unique_integer([:positive])}.mp4"
  end
end
