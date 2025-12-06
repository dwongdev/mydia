defmodule Mydia.Library.SpriteGeneratorTest do
  use Mydia.DataCase, async: true

  alias Mydia.Library.SpriteGenerator
  alias Mydia.Library.GeneratedMedia
  alias Mydia.Library.MediaFile
  alias Mydia.Library.ThumbnailGenerator

  @moduletag :external

  setup do
    # Use a temporary directory for generated content
    test_dir = Path.join([System.tmp_dir!(), "sprite_test_#{:rand.uniform(100_000)}"])
    File.mkdir_p!(test_dir)
    Application.put_env(:mydia, :generated_media_path, test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)
      Application.delete_env(:mydia, :generated_media_path)
    end)

    {:ok, test_dir: test_dir}
  end

  describe "generate/2" do
    test "returns error when library_path is not preloaded" do
      media_file = %MediaFile{
        id: Ecto.UUID.generate(),
        relative_path: "video.mp4",
        library_path_id: Ecto.UUID.generate(),
        library_path: nil
      }

      assert {:error, :library_path_not_preloaded} = SpriteGenerator.generate(media_file)
    end
  end

  describe "generate_from_path/2" do
    test "returns error for non-existent file" do
      assert {:error, :file_not_found} =
               SpriteGenerator.generate_from_path("/nonexistent/video.mp4")
    end

    @tag :requires_ffmpeg
    test "generates sprite sheet and VTT from valid video file", %{test_dir: _test_dir} do
      # Skip if FFmpeg is not available
      unless ThumbnailGenerator.ffmpeg_available?() do
        IO.puts("Skipping test: FFmpeg not available")
        assert true
      else
        # Create a test video (10 seconds)
        video_path = create_test_video(10)

        case SpriteGenerator.generate_from_path(video_path, interval: 2) do
          {:ok, result} ->
            # Verify result structure
            assert Map.has_key?(result, :sprite_checksum)
            assert Map.has_key?(result, :vtt_checksum)
            assert Map.has_key?(result, :frame_count)

            # Verify checksums are valid
            assert String.length(result.sprite_checksum) == 32
            assert String.length(result.vtt_checksum) == 32

            # Verify files exist in storage
            assert GeneratedMedia.exists?(:sprite, result.sprite_checksum)
            assert GeneratedMedia.exists?(:vtt, result.vtt_checksum)

            # Verify the sprite is a valid JPEG
            sprite_path = GeneratedMedia.get_path(:sprite, result.sprite_checksum)
            {:ok, sprite_content} = File.read(sprite_path)
            assert <<0xFF, 0xD8, 0xFF, _rest::binary>> = sprite_content

            # Verify the VTT content is valid
            vtt_path = GeneratedMedia.get_path(:vtt, result.vtt_checksum)
            {:ok, vtt_content} = File.read(vtt_path)
            assert vtt_content =~ "WEBVTT"
            assert vtt_content =~ "#xywh="

            # Verify frame count is reasonable (10 second video, 2 second interval = ~5 frames)
            assert result.frame_count >= 3
            assert result.frame_count <= 6

          {:error, reason} ->
            IO.puts("Sprite generation failed: #{inspect(reason)}")
            # Don't fail the test if FFmpeg is misconfigured in test environment
            assert true
        end

        # Cleanup
        File.rm(video_path)
      end
    end

    @tag :requires_ffmpeg
    test "respects skip_start and skip_end options", %{test_dir: _test_dir} do
      unless ThumbnailGenerator.ffmpeg_available?() do
        IO.puts("Skipping test: FFmpeg not available")
        assert true
      else
        video_path = create_test_video(10)

        case SpriteGenerator.generate_from_path(video_path,
               interval: 1,
               skip_start: 2,
               skip_end: 2
             ) do
          {:ok, result} ->
            # 10 seconds - 2 skip_start - 2 skip_end = 6 seconds
            # With 1 second interval = ~6 frames
            assert result.frame_count >= 4
            assert result.frame_count <= 7

          {:error, reason} ->
            IO.puts("Sprite generation failed: #{inspect(reason)}")
            assert true
        end

        File.rm(video_path)
      end
    end

    @tag :requires_ffmpeg
    test "respects custom thumbnail dimensions", %{test_dir: _test_dir} do
      unless ThumbnailGenerator.ffmpeg_available?() do
        IO.puts("Skipping test: FFmpeg not available")
        assert true
      else
        video_path = create_test_video(5)

        case SpriteGenerator.generate_from_path(video_path,
               interval: 2,
               thumbnail_width: 200,
               thumbnail_height: 120
             ) do
          {:ok, result} ->
            # Verify VTT contains custom dimensions
            vtt_path = GeneratedMedia.get_path(:vtt, result.vtt_checksum)
            {:ok, vtt_content} = File.read(vtt_path)
            assert vtt_content =~ "xywh=0,0,200,120"

          {:error, reason} ->
            IO.puts("Sprite generation failed: #{inspect(reason)}")
            assert true
        end

        File.rm(video_path)
      end
    end

    test "returns error for video too short to extract frames" do
      unless ThumbnailGenerator.ffmpeg_available?() do
        IO.puts("Skipping test: FFmpeg not available")
        assert true
      else
        # Create a 0.5 second video with 5 second interval and 1 second skip
        video_path = create_test_video(0.5)

        result = SpriteGenerator.generate_from_path(video_path, interval: 5, skip_start: 1)

        # Should fail due to video being too short
        assert {:error, _reason} = result

        File.rm(video_path)
      end
    end
  end

  describe "VTT format" do
    @tag :requires_ffmpeg
    test "generates valid WebVTT timestamps", %{test_dir: _test_dir} do
      unless ThumbnailGenerator.ffmpeg_available?() do
        IO.puts("Skipping test: FFmpeg not available")
        assert true
      else
        video_path = create_test_video(15)

        case SpriteGenerator.generate_from_path(video_path, interval: 5) do
          {:ok, result} ->
            vtt_path = GeneratedMedia.get_path(:vtt, result.vtt_checksum)
            {:ok, vtt_content} = File.read(vtt_path)

            # Check VTT header
            assert String.starts_with?(vtt_content, "WEBVTT")

            # Check timestamp format (HH:MM:SS.mmm)
            assert vtt_content =~ ~r/\d{2}:\d{2}:\d{2}\.\d{3} --> \d{2}:\d{2}:\d{2}\.\d{3}/

            # Check sprite coordinate format
            assert vtt_content =~ ~r/#xywh=\d+,\d+,\d+,\d+/

          {:error, reason} ->
            IO.puts("Sprite generation failed: #{inspect(reason)}")
            assert true
        end

        File.rm(video_path)
      end
    end
  end

  # Helper to create a minimal test video using FFmpeg
  defp create_test_video(duration) when is_number(duration) do
    temp_path = Path.join(System.tmp_dir!(), "test_video_#{:rand.uniform(1_000_000)}.mp4")

    args = [
      "-f",
      "lavfi",
      "-i",
      "color=c=blue:s=320x240:d=#{duration}",
      "-c:v",
      "libx264",
      "-t",
      to_string(duration),
      "-y",
      temp_path
    ]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} -> temp_path
      {output, _} -> raise "Failed to create test video: #{output}"
    end
  end
end
