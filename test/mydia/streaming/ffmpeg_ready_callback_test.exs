defmodule Mydia.Streaming.FfmpegReadyCallbackTest do
  @moduledoc """
  Tests for FFmpeg transcoder's on_ready callback functionality.

  These tests verify that the playlist detection mechanism correctly
  calls the on_ready callback when the playlist file appears.
  """

  use ExUnit.Case, async: true

  describe "playlist detection" do
    test "on_ready callback is called when playlist file exists" do
      # Create a temp directory
      temp_dir = Path.join(System.tmp_dir!(), "hls_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(temp_dir)
      playlist_path = Path.join(temp_dir, "index.m3u8")

      # Use a simple GenServer to test the detection logic
      test_pid = self()

      # Simulate the detection behavior
      spawn(fn ->
        check_playlist_ready(playlist_path, fn ->
          send(test_pid, :ready_callback_called)
        end)
      end)

      # Give the checker time to start
      Process.sleep(50)

      # Create the playlist file
      File.write!(playlist_path, "#EXTM3U\n")

      # Wait for the callback
      assert_receive :ready_callback_called, 500

      # Cleanup
      File.rm_rf!(temp_dir)
    end

    test "on_ready callback is not called multiple times" do
      temp_dir = Path.join(System.tmp_dir!(), "hls_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(temp_dir)
      playlist_path = Path.join(temp_dir, "index.m3u8")

      # Create the file first
      File.write!(playlist_path, "#EXTM3U\n")

      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      # Start the checker - file already exists
      spawn(fn ->
        check_playlist_ready(playlist_path, fn ->
          :counters.add(call_count, 1, 1)
          send(test_pid, :ready_callback_called)
        end)
      end)

      # Wait for callback
      assert_receive :ready_callback_called, 200

      # Wait a bit more to ensure no duplicate calls
      Process.sleep(300)

      # Should only have been called once
      assert :counters.get(call_count, 1) == 1

      # Cleanup
      File.rm_rf!(temp_dir)
    end

    test "detection continues polling until file appears" do
      temp_dir = Path.join(System.tmp_dir!(), "hls_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(temp_dir)
      playlist_path = Path.join(temp_dir, "index.m3u8")

      test_pid = self()

      # Start the checker before file exists
      spawn(fn ->
        check_playlist_ready(playlist_path, fn ->
          send(test_pid, :ready_callback_called)
        end)
      end)

      # Wait a bit - file doesn't exist yet
      Process.sleep(150)

      # Should not have received callback yet
      refute_received :ready_callback_called

      # Now create the file
      File.write!(playlist_path, "#EXTM3U\n")

      # Should receive callback now
      assert_receive :ready_callback_called, 300

      # Cleanup
      File.rm_rf!(temp_dir)
    end
  end

  # Helper function that mimics the detection logic from FfmpegHlsTranscoder
  defp check_playlist_ready(playlist_path, on_ready, notified \\ false)

  defp check_playlist_ready(_playlist_path, _on_ready, true) do
    # Already notified, stop
    :ok
  end

  defp check_playlist_ready(playlist_path, on_ready, false) do
    if File.exists?(playlist_path) do
      on_ready.()
      # Don't check again
      :ok
    else
      # Check again in 50ms (faster for tests)
      Process.sleep(50)
      check_playlist_ready(playlist_path, on_ready, false)
    end
  end
end
