defmodule MydiaWeb.MusicLive.ArtistShow do
  use MydiaWeb, :live_view

  alias Mydia.Music

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    artist =
      Music.get_artist!(id,
        preload: [albums: [:artist, tracks: [:music_files]]]
      )

    # Sort albums by release date (newest first)
    albums = Enum.sort_by(artist.albums, & &1.release_date, {:desc, Date})

    {:noreply,
     socket
     |> assign(:page_title, artist.name)
     |> assign(:artist, artist)
     |> assign(:albums, albums)}
  end

  defp get_image_url(artist) do
    if is_binary(artist.image_url) and artist.image_url != "" do
      artist.image_url
    else
      "/images/no-poster.svg"
    end
  end

  defp get_cover_url(album) do
    if is_binary(album.cover_url) and album.cover_url != "" do
      album.cover_url
    else
      "/images/no-poster.svg"
    end
  end

  defp format_year(nil), do: "N/A"
  defp format_year(%Date{year: year}), do: year
  defp format_year(year), do: year

  defp get_album_type_label(album_type) do
    case album_type do
      "album" -> "Album"
      "single" -> "Single"
      "ep" -> "EP"
      "compilation" -> "Compilation"
      _ -> "Album"
    end
  end

  defp count_tracks(album) do
    case album.tracks do
      tracks when is_list(tracks) -> length(tracks)
      _ -> album.total_tracks || 0
    end
  end
end
