defmodule MydiaWeb.BooksLive.AuthorShow do
  use MydiaWeb, :live_view

  alias Mydia.Books

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    author =
      Books.get_author!(id,
        preload: [books: [:author, :book_files]]
      )

    # Group books by series and standalone
    {series_books, standalone_books} =
      Enum.split_with(author.books, &(&1.series_name != nil))

    series_groups =
      series_books
      |> Enum.group_by(& &1.series_name)
      |> Enum.map(fn {series_name, books} ->
        {series_name, Enum.sort_by(books, & &1.series_position)}
      end)
      |> Enum.sort_by(fn {name, _} -> name end)

    standalone_books = Enum.sort_by(standalone_books, & &1.title)

    {:noreply,
     socket
     |> assign(:page_title, author.name)
     |> assign(:author, author)
     |> assign(:series_groups, series_groups)
     |> assign(:standalone_books, standalone_books)}
  end

  defp get_image_url(author) do
    if is_binary(author.image_url) and author.image_url != "" do
      author.image_url
    else
      "/images/no-poster.svg"
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

  defp get_format_badge(book) do
    case book.book_files do
      [file | _] -> String.upcase(file.format || "?")
      _ -> nil
    end
  end

  defp format_badge_class(format) do
    case String.downcase(format || "") do
      "epub" -> "badge-info"
      "pdf" -> "badge-error"
      "mobi" -> "badge-warning"
      "azw3" -> "badge-warning"
      "cbz" -> "badge-success"
      "cbr" -> "badge-success"
      _ -> "badge-ghost"
    end
  end

  defp get_series_position(book) do
    if book.series_position do
      if book.series_position == trunc(book.series_position) do
        trunc(book.series_position)
      else
        book.series_position
      end
    end
  end
end
