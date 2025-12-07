defmodule MydiaWeb.Api.StreamController do
  use MydiaWeb, :controller

  alias Mydia.Library
  alias Mydia.Library.MediaFile
  alias Mydia.Streaming.Compatibility
  alias Mydia.Streaming.FfmpegRemuxer
  alias Mydia.Streaming.{HlsSessionSupervisor, HlsSession}
  alias MydiaWeb.Api.RangeHelper

  require Logger

  @doc """
  Stream a movie by media_item_id.

  Automatically selects the best quality media file available.
  """
  def stream_movie(conn, %{"id" => media_item_id}) do
    try do
      media_item =
        Mydia.Media.get_media_item!(media_item_id, preload: [media_files: :library_path])

      # Select the first (highest quality) media file
      case media_item.media_files do
        [media_file | _] ->
          stream_media_file(conn, media_file)

        [] ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "No media files available for this movie"})
      end
    rescue
      Ecto.NoResultsError ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Movie not found"})
    end
  end

  @doc """
  Stream an episode by episode_id.

  Automatically selects the best quality media file available.
  """
  def stream_episode(conn, %{"id" => episode_id}) do
    try do
      episode = Mydia.Media.get_episode!(episode_id, preload: [media_files: :library_path])

      # Select the first (highest quality) media file
      case episode.media_files do
        [media_file | _] ->
          stream_media_file(conn, media_file)

        [] ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "No media files available for this episode"})
      end
    rescue
      Ecto.NoResultsError ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Episode not found"})
    end
  end

  @doc """
  Unified streaming endpoint that intelligently routes to the optimal streaming method.

  Routes to:
  - Direct play (HTTP Range requests) for browser-compatible files
  - HLS transcoding for incompatible files (when implemented)

  Supports:
  - Full file download (no Range header)
  - Partial content delivery (HTTP 206)
  - Seeking via Range requests
  """
  def stream(conn, %{"id" => media_file_id}) do
    # Load media file with preloads to check access
    try do
      media_file =
        Library.get_media_file!(media_file_id, preload: [:media_item, :episode, :library_path])

      stream_media_file(conn, media_file)
    rescue
      Ecto.NoResultsError ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Media file not found"})
    end
  end

  # Main streaming function that handles a media file
  defp stream_media_file(conn, media_file) do
    Logger.info(
      "Streaming media_file id=#{media_file.id}, codec=#{inspect(media_file.codec)}, " <>
        "audio_codec=#{inspect(media_file.audio_codec)}, container=#{inspect(media_file.metadata["container"])}"
    )

    # Resolve absolute path from relative path and library_path
    case MediaFile.absolute_path(media_file) do
      nil ->
        Logger.error("Cannot resolve path for media_file #{media_file.id}: missing library_path")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Media file path cannot be resolved"})

      absolute_path ->
        # Verify file exists on disk
        if File.exists?(absolute_path) do
          # If codec info is missing, try to extract it on-the-fly
          media_file = maybe_extract_codec_info(media_file, absolute_path)
          route_stream(conn, media_file, absolute_path)
        else
          Logger.warning(
            "Media file #{media_file.id} not found at resolved path: #{absolute_path}"
          )

          conn
          |> put_status(:not_found)
          |> json(%{error: "Media file not found on disk"})
        end
    end
  end

  # Extract codec info on-the-fly if missing from database
  defp maybe_extract_codec_info(%MediaFile{codec: nil} = media_file, absolute_path) do
    Logger.info("Codec info missing for #{media_file.id}, extracting via FFprobe...")

    case Mydia.Library.FileAnalyzer.analyze(absolute_path) do
      {:ok, analysis} ->
        # Update the struct with extracted codec info (in-memory only for now)
        # We use the raw codec_name from FFprobe for compatibility checks
        updated = %{
          media_file
          | codec: normalize_codec_for_compat(analysis.codec),
            audio_codec: normalize_audio_codec_for_compat(analysis.audio_codec)
        }

        Logger.info(
          "Extracted codec info: video=#{inspect(updated.codec)}, audio=#{inspect(updated.audio_codec)}"
        )

        # Also update in database for future requests
        spawn(fn ->
          Library.update_media_file_scan(media_file, %{
            codec: updated.codec,
            audio_codec: updated.audio_codec,
            resolution: analysis.resolution,
            bitrate: analysis.bitrate
          })
        end)

        updated

      {:error, reason} ->
        Logger.warning("Failed to extract codec info for #{media_file.id}: #{inspect(reason)}")
        media_file
    end
  end

  defp maybe_extract_codec_info(media_file, _absolute_path), do: media_file

  # Normalize codec names to raw format for compatibility checks
  # FileAnalyzer returns "H.264 (Main)" but we need "h264" for compatibility
  defp normalize_codec_for_compat(nil), do: nil

  defp normalize_codec_for_compat(codec) do
    normalized = String.downcase(codec)

    cond do
      String.contains?(normalized, "h.264") or String.contains?(normalized, "h264") -> "h264"
      String.contains?(normalized, "h.265") or String.contains?(normalized, "hevc") -> "hevc"
      String.contains?(normalized, "vp9") -> "vp9"
      String.contains?(normalized, "av1") -> "av1"
      String.contains?(normalized, "mpeg-4") or String.contains?(normalized, "mpeg4") -> "mpeg4"
      String.contains?(normalized, "wmv") -> "wmv3"
      true -> codec
    end
  end

  defp normalize_audio_codec_for_compat(nil), do: nil

  defp normalize_audio_codec_for_compat(codec) do
    normalized = String.downcase(codec)

    cond do
      String.contains?(normalized, "aac") -> "aac"
      String.contains?(normalized, "mp3") -> "mp3"
      String.contains?(normalized, "opus") -> "opus"
      String.contains?(normalized, "vorbis") -> "vorbis"
      String.contains?(normalized, "ac3") or String.contains?(normalized, "ac-3") -> "ac3"
      String.contains?(normalized, "dts") -> "dts"
      String.contains?(normalized, "truehd") -> "truehd"
      String.contains?(normalized, "flac") -> "flac"
      true -> codec
    end
  end

  # Routes to appropriate streaming method based on file compatibility
  defp route_stream(conn, media_file, absolute_path) do
    compatibility = Compatibility.check_compatibility(media_file)
    Logger.info("Compatibility check for #{absolute_path}: #{compatibility}")

    case compatibility do
      :direct_play ->
        Logger.info(
          "Streaming #{absolute_path} via direct play (compatible: #{media_file.codec}/#{media_file.audio_codec})"
        )

        stream_file_direct(conn, media_file, absolute_path)

      :needs_remux ->
        reason = Compatibility.remux_reason(media_file)

        Logger.info(
          "Streaming #{absolute_path} via fMP4 remux: #{reason} (codec: #{media_file.codec}/#{media_file.audio_codec})"
        )

        stream_file_remux(conn, media_file, absolute_path)

      :needs_transcoding ->
        reason = Compatibility.transcoding_reason(media_file)

        Logger.info(
          "File #{absolute_path} needs transcoding: #{reason} (codec: #{media_file.codec}, audio: #{media_file.audio_codec})"
        )

        # Start HLS transcoding session
        start_hls_session(conn, media_file, reason)
    end
  end

  defp start_hls_session(conn, media_file, reason) do
    case get_user_id(conn) do
      {:ok, user_id} ->
        Logger.info("Starting HLS session for media_file_id=#{media_file.id}, user_id=#{user_id}")

        case HlsSessionSupervisor.start_session(media_file.id, user_id) do
          {:ok, _pid} ->
            # Get session info to retrieve session_id
            case HlsSessionSupervisor.get_session(media_file.id, user_id) do
              {:ok, session_pid} ->
                case HlsSession.get_info(session_pid) do
                  {:ok, session_info} ->
                    # Construct master playlist URL (use relative path to preserve host)
                    master_playlist_path = ~p"/api/v1/hls/#{session_info.session_id}/index.m3u8"

                    Logger.info(
                      "HLS session started, redirecting to master playlist: #{master_playlist_path}"
                    )

                    # Redirect to master playlist
                    conn
                    |> put_resp_header("location", master_playlist_path)
                    |> send_resp(302, "")

                  {:error, error} ->
                    Logger.error("Failed to get session info: #{inspect(error)}")

                    conn
                    |> put_status(:internal_server_error)
                    |> json(%{error: "Failed to start transcoding session"})
                end

              {:error, error} ->
                Logger.error("Failed to retrieve session: #{inspect(error)}")

                conn
                |> put_status(:internal_server_error)
                |> json(%{error: "Failed to start transcoding session"})
            end

          {:error, :media_file_not_found} ->
            Logger.error("Media file #{media_file.id} not found for HLS session")

            conn
            |> put_status(:not_found)
            |> json(%{error: "Media file not found"})

          {:error, {:pipeline_start_failed, pipeline_error}} ->
            Logger.error("HLS pipeline failed to start: #{inspect(pipeline_error)}")

            conn
            |> put_status(:internal_server_error)
            |> json(%{
              error: "Transcoding failed to start",
              reason: reason,
              details:
                "The transcoding pipeline failed to initialize. MKV files with certain codecs may not be supported yet."
            })

          {:error, error} ->
            Logger.error("Failed to start HLS session: #{inspect(error)}")

            conn
            |> put_status(:internal_server_error)
            |> json(%{
              error: "Transcoding required but failed to start",
              reason: reason,
              details: "Unable to start transcoding session. Please try again later."
            })
        end

      {:error, :no_user} ->
        Logger.warning("HLS transcoding requested but no authenticated user")

        conn
        |> put_status(:unauthorized)
        |> json(%{
          error: "Authentication required for transcoding",
          reason: reason
        })
    end
  end

  defp get_user_id(conn) do
    case Mydia.Auth.Guardian.Plug.current_resource(conn) do
      nil -> {:error, :no_user}
      user -> {:ok, user.id}
    end
  end

  defp stream_file_direct(conn, _media_file, file_path) do
    file_stat = File.stat!(file_path)
    file_size = file_stat.size

    # Get MIME type from file extension
    mime_type = RangeHelper.get_mime_type(file_path)

    # Parse Range header if present
    range_header = get_req_header(conn, "range") |> List.first()

    case RangeHelper.parse_range_header(range_header, file_size) do
      {:ok, start, end_pos} ->
        # Partial content response (206)
        {offset, length} = RangeHelper.calculate_range(start, end_pos)
        content_range = RangeHelper.format_content_range(start, end_pos, file_size)

        conn
        |> put_status(:partial_content)
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_header("content-type", mime_type)
        |> put_resp_header("content-range", content_range)
        |> put_resp_header("content-length", to_string(length))
        |> send_file(:partial_content, file_path, offset, length)

      :error when is_nil(range_header) ->
        # No range header - send full file (200)
        conn
        |> put_status(:ok)
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_header("content-type", mime_type)
        |> put_resp_header("content-length", to_string(file_size))
        |> send_file(:ok, file_path)

      :error ->
        # Invalid range header - return 416 Range Not Satisfiable
        conn
        |> put_status(:requested_range_not_satisfiable)
        |> put_resp_header("content-range", "bytes */#{file_size}")
        |> json(%{error: "Invalid range request"})
    end
  end

  # Stream file via fMP4 remuxing (for files with compatible codecs but incompatible container)
  defp stream_file_remux(conn, _media_file, file_path) do
    case FfmpegRemuxer.start_remux(file_path) do
      {:ok, port, os_pid} ->
        # Stream the remuxed content to the client
        FfmpegRemuxer.stream_to_conn(conn, port, os_pid)

      {:error, :ffmpeg_not_found} ->
        Logger.error("FFmpeg not found on system, cannot remux #{file_path}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Streaming not available", details: "FFmpeg is not installed"})

      {:error, reason} ->
        Logger.error("Failed to start remux for #{file_path}: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to start streaming"})
    end
  end
end
