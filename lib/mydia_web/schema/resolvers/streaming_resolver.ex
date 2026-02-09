defmodule MydiaWeb.Schema.Resolvers.StreamingResolver do
  @moduledoc """
  Resolvers for streaming session management GraphQL mutations.

  These mutations allow P2P clients to start and end HLS streaming sessions
  via GraphQL instead of HTTP endpoints.
  """

  require Logger

  alias Mydia.Library
  alias Mydia.Streaming.Candidates
  alias Mydia.Streaming.HlsSessionSupervisor
  alias Mydia.Streaming.HlsSession

  @doc """
  Returns streaming candidates for a media item.

  This allows P2P clients to determine the optimal streaming strategy
  before initiating playback.
  """
  def streaming_candidates(_parent, %{content_type: content_type, id: id}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      _user ->
        case Candidates.resolve_media_file(content_type, id) do
          {:ok, media_file} ->
            media_file = Candidates.ensure_codec_info(media_file)
            candidates = Candidates.build_streaming_candidates(media_file)
            metadata = Candidates.build_metadata_response(media_file)

            # For relay connections, only allow TRANSCODE (direct play won't work
            # within relay bandwidth limits)
            candidates =
              if context[:peer_connection_type] == "relay" do
                Enum.filter(candidates, fn c -> c.strategy == "TRANSCODE" end)
              else
                candidates
              end

            # Convert string strategies to atoms for the GraphQL enum
            candidates =
              Enum.map(candidates, fn candidate ->
                %{candidate | strategy: strategy_to_atom(candidate.strategy)}
              end)

            {:ok, %{file_id: media_file.id, candidates: candidates, metadata: metadata}}

          {:error, :not_found} ->
            {:error, "#{content_type} not found"}

          {:error, :no_media_files} ->
            {:error, "No media files available"}

          {:error, :invalid_content_type} ->
            {:error, "Invalid content type. Use 'movie', 'episode', or 'file'"}
        end
    end
  end

  defp strategy_to_atom("DIRECT_PLAY"), do: :direct_play
  defp strategy_to_atom("REMUX"), do: :remux
  defp strategy_to_atom("HLS_COPY"), do: :hls_copy
  defp strategy_to_atom("TRANSCODE"), do: :transcode
  defp strategy_to_atom(other), do: String.downcase(other) |> String.to_existing_atom()

  @doc """
  Starts an HLS streaming session for a media file.

  Returns the session ID and media duration for the client to use.
  """
  @relay_bitrate_cap 2000

  def start_streaming_session(_parent, args, %{context: context}) do
    %{file_id: file_id, strategy: strategy} = args

    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        # Determine effective max_bitrate:
        # - For relay connections, cap at @relay_bitrate_cap regardless of request
        # - For direct connections, use player-requested value (nil means CRF default)
        max_bitrate =
          case context[:peer_connection_type] do
            "relay" ->
              min(args[:max_bitrate] || @relay_bitrate_cap, @relay_bitrate_cap)

            _ ->
              args[:max_bitrate]
          end

        start_session_for_user(file_id, user.id, strategy, max_bitrate)
    end
  end

  @doc """
  Ends an HLS streaming session.

  This stops the FFmpeg transcoder and cleans up server-side resources.
  """
  def end_streaming_session(_parent, %{session_id: session_id}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      _user ->
        terminate_session(session_id)
    end
  end

  # Private functions

  defp start_session_for_user(file_id, user_id, strategy, max_bitrate) do
    # Convert strategy to mode
    mode = strategy_to_mode(strategy)

    # Build session opts
    session_opts = if max_bitrate, do: [max_bitrate: max_bitrate], else: []

    # Load media file to get duration
    with {:ok, media_file} <- load_media_file(file_id),
         {:ok, pid} <-
           HlsSessionSupervisor.start_session(media_file.id, user_id, mode, session_opts),
         {:ok, info} <- HlsSession.get_info(pid) do
      # Extract duration from media file metadata
      duration = get_duration_from_metadata(media_file)

      Logger.info(
        "Started streaming session #{info.session_id} for file #{file_id}, user #{user_id}" <>
          if(max_bitrate, do: " (max_bitrate: #{max_bitrate}kbps)", else: "")
      )

      {:ok,
       %{
         session_id: info.session_id,
         duration: duration
       }}
    else
      {:error, reason} ->
        Logger.error("Failed to start streaming session: #{inspect(reason)}")
        {:error, "Failed to start streaming session"}
    end
  end

  defp load_media_file(file_id) do
    {:ok, Library.get_media_file!(file_id)}
  rescue
    Ecto.NoResultsError ->
      {:error, :not_found}
  end

  defp strategy_to_mode(:hls_copy), do: :copy
  defp strategy_to_mode(:transcode), do: :transcode
  defp strategy_to_mode(_), do: :transcode

  defp get_duration_from_metadata(%{metadata: %{"duration" => duration}})
       when is_number(duration) do
    duration
  end

  defp get_duration_from_metadata(_), do: nil

  defp terminate_session(session_id) do
    # Look up session by session_id in the registry
    registry_key = {:session, session_id}

    case Registry.lookup(Mydia.Streaming.HlsSessionRegistry, registry_key) do
      [{pid, _meta}] ->
        # Stop the session
        HlsSession.stop(pid)
        Logger.info("Terminated streaming session #{session_id}")
        {:ok, true}

      [] ->
        # Session not found, but that's okay (may have already timed out)
        Logger.debug("Session #{session_id} not found, may have already terminated")
        {:ok, true}
    end
  end
end
