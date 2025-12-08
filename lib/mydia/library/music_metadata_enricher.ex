defmodule Mydia.Library.MusicMetadataEnricher do
  @moduledoc """
  Enriches music library items with metadata from external providers.
  """

  require Logger
  alias Mydia.{Music, Metadata}
  alias Mydia.Jobs.FetchAlbumCover

  def enrich_artist(%Music.Artist{} = artist) do
    config = Metadata.default_music_relay_config()

    result =
      if artist.musicbrainz_id do
        Metadata.get_artist(config, artist.musicbrainz_id)
      else
        search_artist_by_name(config, artist.name)
      end

    case result do
      {:ok, data} ->
        update_artist(artist, data)

      {:error, reason} ->
        Logger.debug("Could not enrich artist #{artist.name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def enrich_album(%Music.Album{} = album, %Music.Artist{} = artist) do
    config = Metadata.default_music_relay_config()

    result =
      if album.musicbrainz_id do
        Metadata.get_release(config, album.musicbrainz_id)
      else
        search_album(config, album.title, artist.name)
      end

    case result do
      {:ok, data} ->
        update_album(album, data)
        # We also check for cover art existence and update URL if found
        update_cover_art(album, data["id"])

      {:error, reason} ->
        Logger.debug("Could not enrich album #{album.title}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp search_artist_by_name(config, name) do
    case Metadata.search_artist(config, name) do
      {:ok, [match | _]} ->
        Metadata.get_artist(config, match["id"])

      {:ok, []} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  defp search_album(config, title, artist_name) do
    # Search query: "release:title AND artist:name"
    query = "release:\"#{title}\" AND artist:\"#{artist_name}\""

    case Metadata.search_release(config, query) do
      {:ok, [match | _]} ->
        Metadata.get_release(config, match["id"])

      {:ok, []} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  defp update_artist(artist, data) do
    attrs = %{
      musicbrainz_id: data["id"],
      genres: extract_genres(data),
      biography: extract_biography(data)
      # image_url handled separately or via relations later
    }

    Music.update_artist(artist, attrs)
  end

  defp update_album(album, data) do
    attrs = %{
      musicbrainz_id: data["id"],
      release_date: parse_date(data["date"]),
      genres: extract_genres(data),
      album_type: extract_album_type(data)
    }

    Music.update_album(album, attrs)
  end

  defp update_cover_art(album, _mbid) do
    %{album_id: album.id}
    |> FetchAlbumCover.new()
    |> Oban.insert()
  end

  defp extract_genres(data) do
    case Map.get(data, "tags") do
      tags when is_list(tags) ->
        tags
        |> Enum.sort_by(& &1["count"])
        |> Enum.take(5)
        |> Enum.map(& &1["name"])

      _ ->
        []
    end
  end

  defp extract_biography(data) do
    Map.get(data, "disambiguation")
  end

  defp parse_date(nil), do: nil

  defp parse_date(date_str) do
    cond do
      String.match?(date_str, ~r/^\d{4}-\d{2}-\d{2}$/) ->
        Date.from_iso8601!(date_str)

      String.match?(date_str, ~r/^\d{4}$/) ->
        Date.new!(String.to_integer(date_str), 1, 1)

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  defp extract_album_type(data) do
    get_in(data, ["release-group", "primary-type"]) |> String.downcase()
  rescue
    _ -> "album"
  end
end
