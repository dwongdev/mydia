defmodule Mydia.Jobs.FetchAlbumCover do
  use Oban.Worker, queue: :media, max_attempts: 3

  require Logger
  alias Mydia.{Music, Metadata}
  alias Mydia.Library.{CoverExtractor, GeneratedMedia}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"album_id" => album_id}}) do
    album = Music.get_album!(album_id)

    # Priority 1: Cover Art Archive (if MBID exists)
    with {:error, _} <- fetch_from_caa(album),
         {:error, _} <- fetch_embedded_art(album) do
      Logger.debug("No cover art found for album #{album.id}")
      :ok
    else
      {:ok, blob, source} ->
        store_cover(album, blob, source)
    end
  end

  defp fetch_from_caa(album) do
    if album.musicbrainz_id do
      config = Metadata.default_music_relay_config()

      case Metadata.get_cover_art(config, album.musicbrainz_id) do
        {:ok, blob} when is_binary(blob) -> {:ok, blob, "musicbrainz"}
        _ -> {:error, :not_found}
      end
    else
      {:error, :no_mbid}
    end
  end

  defp fetch_embedded_art(album) do
    # Try to get first track file path
    # We need to preload tracks or just query one. 
    # Music.list_tracks sorts by disc/track number, which is good.
    case Music.list_tracks(album_id: album.id) do
      tracks when tracks != [] ->
        # Iterate tracks until we find one with a file and art
        Enum.find_value(tracks, {:error, :no_cover}, fn track ->
          case Music.list_music_files(track_id: track.id) do
            [file | _] ->
              case CoverExtractor.extract(file.path) do
                {:ok, blob} -> {:ok, blob, "embedded"}
                _ -> nil
              end

            _ ->
              nil
          end
        end)

      [] ->
        {:error, :no_tracks}
    end
  end

  defp store_cover(album, blob, source) do
    case GeneratedMedia.store(:cover, blob) do
      {:ok, checksum} ->
        {:ok, _} =
          Music.update_album(album, %{
            cover_blob: checksum,
            cover_source: source,
            cover_url: "/covers/#{album.id}"
          })

        :ok

      {:error, reason} ->
        Logger.error("Failed to store cover for album #{album.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
