defmodule MydiaWeb.BooksLive.Show do
  use MydiaWeb, :live_view

  alias Mydia.Books

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    book =
      Books.get_book!(id,
        preload: [:author, :book_files]
      )

    {:noreply,
     socket
     |> assign(:page_title, book.title)
     |> assign(:book, book)}
  end

  @impl true
  def handle_event("toggle_monitored", _params, socket) do
    book = socket.assigns.book
    new_monitored_status = !book.monitored

    case Books.update_book(book, %{monitored: new_monitored_status}) do
      {:ok, updated_book} ->
        {:noreply,
         socket
         |> assign(:book, %{socket.assigns.book | monitored: updated_book.monitored})
         |> put_flash(
           :info,
           "Monitoring #{if new_monitored_status, do: "enabled", else: "disabled"}"
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update monitoring status")}
    end
  end

  defp get_cover_url(book) do
    if is_binary(book.cover_url) and book.cover_url != "" do
      book.cover_url
    else
      "/images/no-poster.svg"
    end
  end

  defp format_year(nil), do: "N/A"
  defp format_year(%Date{year: year}), do: year
  defp format_year(year), do: year

  defp get_series_info(book) do
    if book.series_name do
      if book.series_position do
        "#{book.series_name} ##{format_series_position(book.series_position)}"
      else
        book.series_name
      end
    else
      nil
    end
  end

  defp format_series_position(position) when is_float(position) do
    if Float.floor(position) == position do
      trunc(position)
    else
      position
    end
  end

  defp format_series_position(position), do: position

  defp format_badge_class("epub"), do: "badge-success"
  defp format_badge_class("pdf"), do: "badge-warning"
  defp format_badge_class("mobi"), do: "badge-info"
  defp format_badge_class("azw3"), do: "badge-info"
  defp format_badge_class("cbz"), do: "badge-secondary"
  defp format_badge_class("cbr"), do: "badge-secondary"
  defp format_badge_class(_), do: "badge-ghost"

  defp total_file_size(book) do
    case book.book_files do
      files when is_list(files) ->
        files
        |> Enum.map(& &1.size)
        |> Enum.reject(&is_nil/1)
        |> Enum.sum()

      _ ->
        0
    end
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
