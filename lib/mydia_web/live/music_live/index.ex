defmodule MydiaWeb.MusicLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.Music

  @items_per_page 50
  @items_per_scroll 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:view_mode, :grid)
     |> assign(:search_query, "")
     |> assign(:filter_monitored, nil)
     |> assign(:filter_album_type, nil)
     |> assign(:sort_by, "title_asc")
     |> assign(:page, 0)
     |> assign(:has_more, true)
     |> assign(:page_title, "Music")
     |> stream(:albums, [])}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, load_albums(socket, reset: true)}
  end

  @impl true
  def handle_event("toggle_view", %{"mode" => mode}, socket) do
    view_mode = String.to_existing_atom(mode)

    {:noreply,
     socket
     |> assign(:view_mode, view_mode)
     |> assign(:page, 0)
     |> load_albums(reset: true)}
  end

  def handle_event("search", params, socket) do
    query = params["search"] || params["value"] || ""

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:page, 0)
     |> load_albums(reset: true)}
  end

  def handle_event("filter", params, socket) do
    monitored =
      case params["monitored"] do
        "all" -> nil
        "true" -> true
        "false" -> false
        _ -> nil
      end

    album_type =
      case params["album_type"] do
        "" -> nil
        type when type in ["album", "single", "ep", "compilation"] -> type
        _ -> nil
      end

    sort_by = params["sort_by"] || socket.assigns.sort_by

    {:noreply,
     socket
     |> assign(:filter_monitored, monitored)
     |> assign(:filter_album_type, album_type)
     |> assign(:sort_by, sort_by)
     |> assign(:page, 0)
     |> load_albums(reset: true)}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more do
      {:noreply,
       socket
       |> update(:page, &(&1 + 1))
       |> load_albums(reset: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_album_monitored", %{"id" => id}, socket) do
    album = Music.get_album!(id)
    new_monitored_status = !album.monitored

    case Music.update_album(album, %{monitored: new_monitored_status}) do
      {:ok, _updated_album} ->
        updated_album_with_preloads =
          Music.get_album!(id, preload: [:artist, tracks: :music_files])

        {:noreply,
         socket
         |> stream_insert(:albums, updated_album_with_preloads)
         |> put_flash(
           :info,
           "Monitoring #{if new_monitored_status, do: "enabled", else: "disabled"}"
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update monitoring status")}
    end
  end

  defp load_albums(socket, opts) do
    reset? = Keyword.get(opts, :reset, false)
    page = if reset?, do: 0, else: socket.assigns.page
    offset = if page == 0, do: 0, else: @items_per_page + (page - 1) * @items_per_scroll
    limit = if page == 0, do: @items_per_page, else: @items_per_scroll

    query_opts =
      []
      |> maybe_add_filter(:monitored, socket.assigns.filter_monitored)
      |> maybe_add_filter(:album_type, socket.assigns.filter_album_type)
      |> maybe_add_filter(:search, socket.assigns.search_query)
      |> Keyword.put(:preload, [:artist, tracks: :music_files])

    all_albums = Music.list_albums(query_opts)

    # Apply sorting
    albums = apply_sorting(all_albums, socket.assigns.sort_by)

    # Apply pagination
    paginated_albums = albums |> Enum.drop(offset) |> Enum.take(limit)
    has_more = length(albums) > offset + limit

    socket =
      socket
      |> assign(:has_more, has_more)
      |> assign(:albums_empty?, reset? and albums == [])

    if reset? do
      stream(socket, :albums, paginated_albums, reset: true)
    else
      stream(socket, :albums, paginated_albums)
    end
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, _key, ""), do: opts
  defp maybe_add_filter(opts, key, value), do: Keyword.put(opts, key, value)

  defp apply_sorting(albums, sort_by) do
    case sort_by do
      "title_asc" ->
        Enum.sort_by(albums, &String.downcase(&1.title || ""), :asc)

      "title_desc" ->
        Enum.sort_by(albums, &String.downcase(&1.title || ""), :desc)

      "year_asc" ->
        Enum.sort_by(albums, &get_year(&1), :asc)

      "year_desc" ->
        Enum.sort_by(albums, &get_year(&1), :desc)

      "added_asc" ->
        Enum.sort_by(albums, & &1.inserted_at, :asc)

      "added_desc" ->
        Enum.sort_by(albums, & &1.inserted_at, :desc)

      "artist_asc" ->
        Enum.sort_by(albums, &get_artist_name(&1), :asc)

      "artist_desc" ->
        Enum.sort_by(albums, &get_artist_name(&1), :desc)

      _ ->
        Enum.sort_by(albums, &String.downcase(&1.title || ""), :asc)
    end
  end

  defp get_year(%{release_date: nil}), do: 0
  defp get_year(%{release_date: date}), do: date.year

  defp get_artist_name(%{artist: %{name: name}}) when is_binary(name),
    do: String.downcase(name)

  defp get_artist_name(_), do: ""

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

  defp get_track_count(%{total_tracks: count}) when is_integer(count) and count > 0, do: count
  defp get_track_count(%{tracks: tracks}) when is_list(tracks), do: length(tracks)
  defp get_track_count(_), do: 0

  defp get_quality_badge(album) do
    tracks = album.tracks || []

    bitrate =
      tracks
      |> Enum.flat_map(fn track ->
        case track.music_files do
          files when is_list(files) -> files
          _ -> []
        end
      end)
      |> Enum.map(& &1.bitrate)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> nil end)

    format_bitrate(bitrate)
  end

  defp format_bitrate(nil), do: nil
  defp format_bitrate(bitrate) when bitrate >= 320, do: "FLAC"
  defp format_bitrate(bitrate) when bitrate >= 256, do: "320kbps"
  defp format_bitrate(bitrate) when bitrate >= 192, do: "256kbps"
  defp format_bitrate(bitrate) when bitrate >= 128, do: "192kbps"
  defp format_bitrate(_), do: nil

  defp get_album_type_badge(album_type) do
    case album_type do
      "album" -> nil
      "single" -> "Single"
      "ep" -> "EP"
      "compilation" -> "Compilation"
      _ -> nil
    end
  end

  defp total_file_size(album) do
    tracks = album.tracks || []

    tracks
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
end
