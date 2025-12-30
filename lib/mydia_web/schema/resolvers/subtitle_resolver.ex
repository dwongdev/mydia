defmodule MydiaWeb.Schema.Resolvers.SubtitleResolver do
  @moduledoc """
  Resolvers for subtitle-related GraphQL fields.
  """

  alias Mydia.Library
  alias Mydia.Subtitles.Extractor

  require Logger

  @doc """
  Lists all available subtitle tracks for a media file.

  Returns both embedded subtitles (from the media file) and external subtitle files.
  """
  def list_subtitles(%{id: media_file_id} = media_file, _args, _info) do
    # Ensure library_path is preloaded
    media_file =
      if Ecto.assoc_loaded?(media_file.library_path) do
        media_file
      else
        Library.get_media_file!(media_file_id, preload: [:library_path])
      end

    tracks = Extractor.list_subtitle_tracks(media_file)

    # Add the media_file_id to each track so the URL resolver can access it
    tracks_with_metadata =
      Enum.map(tracks, fn track ->
        track
        |> Map.put(:_media_file_id, media_file_id)
        |> normalize_track_id()
      end)

    {:ok, tracks_with_metadata}
  rescue
    Ecto.NoResultsError ->
      {:ok, []}

    e ->
      Logger.error("Failed to list subtitles: #{inspect(e)}")
      {:ok, []}
  end

  # Normalize track_id to always be a string for consistency
  defp normalize_track_id(%{track_id: track_id} = track) when is_integer(track_id) do
    %{track | track_id: Integer.to_string(track_id)}
  end

  defp normalize_track_id(track), do: track
end
