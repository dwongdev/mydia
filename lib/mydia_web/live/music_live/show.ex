defmodule MydiaWeb.MusicLive.Show do
  use MydiaWeb, :live_view

  alias Mydia.Music

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    album =
      Music.get_album!(id,
        preload: [:artist, tracks: [:artist, :music_files]]
      )

    {:noreply,
     socket
     |> assign(:page_title, album.title)
     |> assign(:album, album)}
  end

  @impl true
  def handle_event("toggle_monitored", _params, socket) do
    album = socket.assigns.album
    new_monitored_status = !album.monitored

    case Music.update_album(album, %{monitored: new_monitored_status}) do
      {:ok, updated_album} ->
        {:noreply,
         socket
         |> assign(:album, %{socket.assigns.album | monitored: updated_album.monitored})
         |> put_flash(
           :info,
           "Monitoring #{if new_monitored_status, do: "enabled", else: "disabled"}"
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update monitoring status")}
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

  defp format_track_duration(nil), do: "-"

  defp format_track_duration(seconds) when is_integer(seconds) do
    minutes = div(seconds, 60)
    remaining_seconds = rem(seconds, 60)
    "#{minutes}:#{String.pad_leading(to_string(remaining_seconds), 2, "0")}"
  end

  defp get_total_duration(album) do
    case album.total_duration do
      duration when is_integer(duration) and duration > 0 ->
        duration

      _ ->
        album.tracks
        |> Enum.map(& &1.duration)
        |> Enum.reject(&is_nil/1)
        |> Enum.sum()
    end
  end

  defp format_total_duration(seconds) when is_integer(seconds) and seconds > 0 do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)

    if hours > 0 do
      "#{hours}h #{minutes}m"
    else
      "#{minutes} min"
    end
  end

  defp format_total_duration(_), do: "-"

  defp total_file_size(album) do
    album.tracks
    |> Enum.flat_map(fn track ->
      case track.music_files do
        files when is_list(files) -> files
        _ -> []
      end
    end)
    |> Enum.map(& &1.size)
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  defp format_file_size(0), do: "-"
  defp format_file_size(nil), do: "-"

  defp format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp get_album_type_label(album_type) do
    case album_type do
      "album" -> "Album"
      "single" -> "Single"
      "ep" -> "EP"
      "compilation" -> "Compilation"
      _ -> "Album"
    end
  end

  defp track_has_file?(track) do
    case track.music_files do
      files when is_list(files) and files != [] -> true
      _ -> false
    end
  end
end
