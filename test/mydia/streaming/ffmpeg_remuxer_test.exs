defmodule Mydia.Streaming.FfmpegRemuxerTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.FfmpegRemuxer

  @moduletag :external

  describe "start_remux/2" do
    @tag :external
    test "starts FFmpeg process for valid video file" do
      # Create a small test video file using FFmpeg
      test_dir = System.tmp_dir!()
      input_path = Path.join(test_dir, "test_remux_input_#{:rand.uniform(100_000)}.mkv")

      # Generate a 1-second test video
      {_, 0} =
        System.cmd(
          "ffmpeg",
          [
            "-f",
            "lavfi",
            "-i",
            "testsrc=duration=1:size=320x240:rate=30",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=1000:duration=1",
            "-c:v",
            "libx264",
            "-c:a",
            "aac",
            "-y",
            input_path
          ],
          stderr_to_stdout: true
        )

      on_exit(fn -> File.rm(input_path) end)

      # Start remux
      assert {:ok, port, os_pid} = FfmpegRemuxer.start_remux(input_path)
      assert is_port(port)
      assert is_integer(os_pid)
      assert os_pid > 0

      # Clean up
      FfmpegRemuxer.stop_remux(port, os_pid)
    end

    @tag :external
    test "returns error for non-existent file" do
      # FFmpeg will fail when the file doesn't exist
      {:ok, port, _os_pid} = FfmpegRemuxer.start_remux("/nonexistent/path/video.mkv")

      # Receive the exit status - should be non-zero
      assert_receive {^port, {:exit_status, status}}, 5000
      assert status != 0
    end

    @tag :external
    test "supports seek_seconds option" do
      test_dir = System.tmp_dir!()
      input_path = Path.join(test_dir, "test_seek_input_#{:rand.uniform(100_000)}.mkv")

      # Generate a 3-second test video
      {_, 0} =
        System.cmd(
          "ffmpeg",
          [
            "-f",
            "lavfi",
            "-i",
            "testsrc=duration=3:size=320x240:rate=30",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=1000:duration=3",
            "-c:v",
            "libx264",
            "-c:a",
            "aac",
            "-y",
            input_path
          ],
          stderr_to_stdout: true
        )

      on_exit(fn -> File.rm(input_path) end)

      # Start remux with seek
      assert {:ok, port, os_pid} = FfmpegRemuxer.start_remux(input_path, seek_seconds: 1)
      assert is_port(port)
      assert is_integer(os_pid)

      # Clean up
      FfmpegRemuxer.stop_remux(port, os_pid)
    end
  end

  describe "stop_remux/2" do
    @tag :external
    test "stops running FFmpeg process" do
      test_dir = System.tmp_dir!()
      input_path = Path.join(test_dir, "test_stop_input_#{:rand.uniform(100_000)}.mkv")

      # Generate a longer test video
      {_, 0} =
        System.cmd(
          "ffmpeg",
          [
            "-f",
            "lavfi",
            "-i",
            "testsrc=duration=5:size=320x240:rate=30",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=1000:duration=5",
            "-c:v",
            "libx264",
            "-c:a",
            "aac",
            "-y",
            input_path
          ],
          stderr_to_stdout: true
        )

      on_exit(fn -> File.rm(input_path) end)

      {:ok, port, os_pid} = FfmpegRemuxer.start_remux(input_path)

      # Process should be alive
      assert Port.info(port) != nil

      # Stop the process
      assert :ok = FfmpegRemuxer.stop_remux(port, os_pid)

      # Give it a moment
      Process.sleep(100)

      # Port should be closed
      assert Port.info(port) == nil
    end
  end

  describe "ffmpeg availability" do
    @describetag :external

    test "FFmpeg is available on the system" do
      assert System.find_executable("ffmpeg") != nil
    end
  end
end
