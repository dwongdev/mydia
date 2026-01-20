defmodule MydiaWeb.Api.StreamController do
  use MydiaWeb, :controller

  alias Mydia.Library
  alias Mydia.Library.MediaFile

  alias Mydia.Streaming.{
    Codec,
    CodecString,
    Compatibility,
    FfmpegRemuxer,
    HlsSession,
    HlsSessionSupervisor,
    DirectPlaySession
  }

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

  @doc """
  Returns a prioritized list of streaming candidates for a media file.

  The client should iterate through the candidates using browser APIs
  (MediaCapabilities, MediaSource.isTypeSupported, canPlayType) to find
  the first supported option, then use that strategy when calling the
  stream endpoint.

  ## Parameters

  - content_type: "movie" or "episode"
  - id: The media item ID or episode ID

  ## Response

  Returns JSON with candidates array and metadata:

      {
        "candidates": [
          {
            "strategy": "DIRECT_PLAY",
            "mime": "video/mp4; codecs=\"avc1.640028, mp4a.40.2\"",
            "container": "mp4",
            "video_codec": "avc1.640028",
            "audio_codec": "mp4a.40.2"
          },
          ...
        ],
        "metadata": {
          "duration": 596.5,
          "width": 1920,
          "height": 1080,
          "bitrate": 5000000
        }
      }
  """
  def candidates(conn, %{"content_type" => content_type, "id" => id}) do
    result =
      case content_type do
        "movie" ->
          try do
            media_item =
              Mydia.Media.get_media_item!(id, preload: [media_files: :library_path])

            case media_item.media_files do
              [media_file | _] -> {:ok, media_file}
              [] -> {:error, :no_media_files}
            end
          rescue
            Ecto.NoResultsError -> {:error, :not_found}
          end

        "episode" ->
          try do
            episode = Mydia.Media.get_episode!(id, preload: [media_files: :library_path])

            case episode.media_files do
              [media_file | _] -> {:ok, media_file}
              [] -> {:error, :no_media_files}
            end
          rescue
            Ecto.NoResultsError -> {:error, :not_found}
          end

        "file" ->
          # Direct media file access by ID
          try do
            media_file = Library.get_media_file!(id, preload: [:library_path])
            {:ok, media_file}
          rescue
            Ecto.NoResultsError -> {:error, :not_found}
          end

        _ ->
          {:error, :invalid_content_type}
      end

    case result do
      {:ok, media_file} ->
        candidates_response(conn, media_file)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "#{content_type} not found"})

      {:error, :no_media_files} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "No media files available"})

      {:error, :invalid_content_type} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid content type. Use 'movie', 'episode', or 'file'"})
    end
  end

  defp candidates_response(conn, media_file) do
    # Ensure we have codec info (may need to extract on-the-fly)
    absolute_path = MediaFile.absolute_path(media_file)

    media_file =
      if absolute_path && File.exists?(absolute_path) do
        maybe_extract_codec_info(media_file, absolute_path)
      else
        media_file
      end

    # Generate streaming candidates
    candidates = build_streaming_candidates(media_file)

    # Build metadata response
    metadata = build_metadata_response(media_file)

    json(conn, %{
      candidates: candidates,
      metadata: metadata
    })
  end

  defp build_streaming_candidates(media_file) do
    compatibility = Compatibility.check_compatibility(media_file)
    metadata = media_file.metadata || %{}
    # Use the same container detection as compatibility check
    container = Compatibility.get_container_format(media_file)

    # Generate RFC 6381 codec strings
    video_codec_str = CodecString.video_codec_string(media_file.codec, metadata)
    audio_codec_str = CodecString.audio_codec_string(media_file.audio_codec, metadata)

    # Get codec variants for browser testing
    video_variants = CodecString.video_codec_variants(media_file.codec, metadata)

    # Build prioritized candidate list based on compatibility
    case compatibility do
      :direct_play ->
        # File can be played directly - offer direct play plus transcode fallback
        [
          build_candidate("DIRECT_PLAY", container, video_codec_str, audio_codec_str),
          # Always include transcode fallback in case direct play fails
          build_candidate("TRANSCODE", "ts", "avc1.640028", "mp4a.40.2")
        ]

      :needs_remux ->
        # Codecs are compatible, just need container conversion to fMP4
        [
          build_candidate("REMUX", "mp4", video_codec_str, audio_codec_str),
          build_candidate("HLS_COPY", "ts", video_codec_str, audio_codec_str),
          build_candidate("TRANSCODE", "ts", "avc1.640028", "mp4a.40.2")
        ]

      :needs_transcoding ->
        # Build candidates for browsers that might support the codec natively
        # (e.g., Safari with HEVC) plus transcode fallback
        native_candidates =
          Enum.map(video_variants, fn video_variant ->
            build_candidate("HLS_COPY", "ts", video_variant, audio_codec_str)
          end)

        # Add transcode fallback (always H.264 + AAC which all browsers support)
        transcode_candidate =
          build_candidate("TRANSCODE", "ts", "avc1.640028", "mp4a.40.2")

        native_candidates ++ [transcode_candidate]
    end
  end

  defp build_candidate(strategy, container, video_codec, audio_codec) do
    mime = CodecString.build_mime_type(container, video_codec, audio_codec)

    %{
      strategy: strategy,
      mime: mime,
      container: container,
      video_codec: video_codec,
      audio_codec: audio_codec
    }
  end

  defp build_metadata_response(media_file) do
    metadata = media_file.metadata || %{}

    %{
      duration: metadata["duration"],
      width: metadata["width"],
      height: metadata["height"],
      bitrate: media_file.bitrate,
      resolution: media_file.resolution,
      hdr_format: media_file.hdr_format,
      original_codec: media_file.codec,
      original_audio_codec: media_file.audio_codec,
      container: metadata["container"]
    }
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
        # Also update metadata with container format and duration for compatibility checks
        updated_metadata =
          (media_file.metadata || %{})
          |> Map.put("container", analysis.container)
          |> maybe_put_duration(analysis.duration)

        updated = %{
          media_file
          | codec: Codec.normalize_video_codec(analysis.codec),
            audio_codec: Codec.normalize_audio_codec(analysis.audio_codec),
            metadata: updated_metadata
        }

        Logger.info(
          "Extracted codec info: video=#{inspect(updated.codec)}, audio=#{inspect(updated.audio_codec)}, container=#{inspect(analysis.container)}, duration=#{inspect(analysis.duration)}"
        )

        # Also update in database for future requests
        spawn(fn ->
          Library.update_media_file_scan(media_file, %{
            codec: updated.codec,
            audio_codec: updated.audio_codec,
            resolution: analysis.resolution,
            bitrate: analysis.bitrate,
            metadata: updated_metadata
          })
        end)

        updated

      {:error, reason} ->
        Logger.warning("Failed to extract codec info for #{media_file.id}: #{inspect(reason)}")
        media_file
    end
  end

  # Extract fresh duration if missing from metadata (needed for remuxing/transcoding)
  defp maybe_extract_codec_info(media_file, absolute_path) do
    # Even if codec info exists, we need to ensure duration is present for proper playback
    case get_in(media_file.metadata || %{}, ["duration"]) do
      nil ->
        # Duration is missing - probe the file to get fresh duration
        Logger.info("Duration missing for #{media_file.id}, extracting via FFprobe...")
        extract_duration_only(media_file, absolute_path)

      _duration ->
        # Duration already present
        media_file
    end
  end

  # Extract only duration when other codec info is already present
  defp extract_duration_only(media_file, absolute_path) do
    case Mydia.Library.ThumbnailGenerator.get_duration(absolute_path) do
      {:ok, duration} ->
        updated_metadata =
          (media_file.metadata || %{})
          |> Map.put("duration", duration)

        Logger.info("Extracted duration: #{duration}s for #{media_file.id}")

        # Update in database for future requests
        spawn(fn ->
          Library.update_media_file_scan(media_file, %{metadata: updated_metadata})
        end)

        %{media_file | metadata: updated_metadata}

      {:error, reason} ->
        Logger.warning("Failed to extract duration for #{media_file.id}: #{inspect(reason)}")
        media_file
    end
  end

  defp maybe_put_duration(metadata, nil), do: metadata
  defp maybe_put_duration(metadata, duration), do: Map.put(metadata, "duration", duration)

  # Routes to appropriate streaming method based on client-selected strategy
  # or falls back to auto-detection for backward compatibility
  defp route_stream(conn, media_file, absolute_path) do
    # Check if client specified a strategy (new candidates-based approach)
    strategy = conn.query_params["strategy"]

    if strategy do
      # Client has explicitly selected a strategy via candidates API
      route_with_strategy(conn, media_file, absolute_path, strategy)
    else
      # Fallback to legacy auto-detection (for backward compatibility)
      route_with_auto_detection(conn, media_file, absolute_path)
    end
  end

  # Route based on client-selected strategy from candidates API
  defp route_with_strategy(conn, media_file, absolute_path, strategy) do
    Logger.info(
      "Streaming #{absolute_path} with client-selected strategy: #{strategy} (codec: #{media_file.codec}/#{media_file.audio_codec})"
    )

    case strategy do
      "DIRECT_PLAY" ->
        stream_file_direct(conn, media_file, absolute_path)

      "REMUX" ->
        stream_file_remux(conn, media_file, absolute_path)

      "HLS_COPY" ->
        reason = "Client selected HLS with stream copy"
        start_hls_session(conn, media_file, reason, :copy)

      "TRANSCODE" ->
        reason = "Client selected transcoding"
        start_hls_session(conn, media_file, reason, :transcode)

      _ ->
        Logger.warning("Unknown strategy: #{strategy}, falling back to auto-detection")
        route_with_auto_detection(conn, media_file, absolute_path)
    end
  end

  # Legacy auto-detection based on compatibility check (for backward compatibility)
  # New clients should use the candidates API with explicit strategy parameter
  defp route_with_auto_detection(conn, media_file, absolute_path) do
    compatibility = Compatibility.check_compatibility(media_file)

    Logger.info("Auto-detecting stream method for #{absolute_path}: #{compatibility}")

    case compatibility do
      :direct_play ->
        Logger.info(
          "Streaming #{absolute_path} via direct play (compatible: #{media_file.codec}/#{media_file.audio_codec})"
        )

        stream_file_direct(conn, media_file, absolute_path)

      :needs_remux ->
        # Default to remux - modern browsers support fMP4
        reason = Compatibility.remux_reason(media_file)

        Logger.info(
          "Streaming #{absolute_path} via fMP4 remux: #{reason} (codec: #{media_file.codec}/#{media_file.audio_codec})"
        )

        stream_file_remux(conn, media_file, absolute_path)

      :needs_transcoding ->
        # Default to transcoding for incompatible codecs
        reason = Compatibility.transcoding_reason(media_file)

        Logger.info(
          "File #{absolute_path} needs transcoding: #{reason} (codec: #{media_file.codec}, audio: #{media_file.audio_codec})"
        )

        start_hls_session(conn, media_file, reason, :transcode)
    end
  end

  defp start_hls_session(conn, media_file, reason, hls_mode) do
    case get_user_id(conn) do
      {:ok, user_id} ->
        Logger.info(
          "Starting HLS session for media_file_id=#{media_file.id}, user_id=#{user_id}, mode=#{hls_mode}"
        )

        case HlsSessionSupervisor.start_session(media_file.id, user_id, hls_mode) do
          {:ok, _pid} ->
            # Get session info to retrieve session_id
            case HlsSessionSupervisor.get_session(media_file.id, user_id) do
              {:ok, session_pid} ->
                case HlsSession.get_info(session_pid) do
                  {:ok, session_info} ->
                    # Construct master playlist URL with mode query param
                    # mode=copy means stream copy (no re-encoding), mode=transcode means actual transcoding
                    master_playlist_path =
                      ~p"/api/v1/hls/#{session_info.session_id}/index.m3u8?mode=#{hls_mode}"

                    Logger.info(
                      "HLS session started (#{hls_mode}), master playlist: #{master_playlist_path}"
                    )

                    # Check if client wants JSON response instead of redirect
                    # Web browsers can't reliably follow redirects with fetch API
                    if conn.query_params["resolve"] == "json" do
                      # Return the HLS URL as JSON for web clients
                      # Include duration so player can show correct total time
                      # (HLS live playlists don't include total duration)
                      duration = get_in(media_file.metadata || %{}, ["duration"])
                      json(conn, %{hls_url: master_playlist_path, duration: duration})
                    else
                      # Redirect to master playlist (native clients)
                      conn
                      |> put_resp_header("location", master_playlist_path)
                      |> send_resp(302, "")
                    end

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

  defp stream_file_direct(conn, media_file, file_path) when conn.method != "HEAD" do
    # Start tracking direct play session if user is authenticated
    case get_user_id(conn) do
      {:ok, user_id} ->
        case HlsSessionSupervisor.start_direct_session(media_file.id, user_id) do
          {:ok, pid} ->
            DirectPlaySession.heartbeat(pid)

          error ->
            Logger.warning("Failed to start direct play session tracker: #{inspect(error)}")
        end

      _ ->
        :ok
    end

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
        |> put_resp_header("x-streaming-mode", "direct")
        |> send_file(:partial_content, file_path, offset, length)

      :error when is_nil(range_header) ->
        # No range header - send full file (200)
        conn
        |> put_status(:ok)
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_header("content-type", mime_type)
        |> put_resp_header("content-length", to_string(file_size))
        |> put_resp_header("x-streaming-mode", "direct")
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
  defp stream_file_remux(conn, _media_file, _file_path) when conn.method == "HEAD" do
    # For HEAD requests, just return headers without starting the remux process
    # This allows clients to detect the streaming mode without triggering FFmpeg
    conn
    |> put_resp_content_type("video/mp4")
    |> put_resp_header("x-streaming-mode", "remux")
    |> send_resp(200, "")
  end

  defp stream_file_remux(conn, media_file, file_path) do
    # Get duration - first try metadata, then probe fresh from file
    duration = get_duration_for_remux(media_file, file_path)

    Logger.info("Starting remux for #{file_path} with duration: #{inspect(duration)}")

    case FfmpegRemuxer.start_remux(file_path, duration: duration) do
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

  # Get duration for remuxing - try metadata first, then probe fresh
  defp get_duration_for_remux(media_file, file_path) do
    case get_in(media_file.metadata || %{}, ["duration"]) do
      duration when is_number(duration) and duration > 0 ->
        duration

      _ ->
        # Probe fresh from file
        case Mydia.Library.ThumbnailGenerator.get_duration(file_path) do
          {:ok, duration} when duration > 0 ->
            Logger.info("Probed fresh duration: #{duration}s")
            duration

          _ ->
            nil
        end
    end
  end
end
