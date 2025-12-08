defmodule Mydia.Metadata.Provider.OpenLibrary do
  @moduledoc """
  Metadata provider adapter for Open Library via metadata-relay.
  """
  @behaviour Mydia.Metadata.Provider

  alias Mydia.Metadata.Provider.{Error, HTTP}
  alias Mydia.Metadata.Structs.{BookMetadata, SearchResult}

  @impl true
  def test_connection(config) do
    req = HTTP.new_request(config)

    case HTTP.get(req, "/openlibrary/search", params: [q: "the", limit: 1]) do
      {:ok, %{status: 200}} -> {:ok, %{status: "ok", provider: "open_library"}}
      {:ok, %{status: status}} -> {:error, Error.connection_failed("Status #{status}")}
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def search(config, query, _opts \\ []) do
    req = HTTP.new_request(config)

    case HTTP.get(req, "/openlibrary/search", params: [q: query]) do
      {:ok, %{status: 200, body: body}} ->
        results = parse_search_results(body)
        {:ok, results}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Search failed #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def fetch_by_id(config, provider_id, _opts \\ []) do
    req = HTTP.new_request(config)

    {endpoint, id_type} =
      if String.starts_with?(provider_id, "ISBN:") do
        isbn = String.replace_prefix(provider_id, "ISBN:", "")
        {"/openlibrary/isbn/#{isbn}", :isbn}
      else
        # Assume OLID
        {"/openlibrary/works/#{provider_id}", :olid}
      end

    case HTTP.get(req, endpoint) do
      {:ok, %{status: 200, body: body}} ->
        metadata = parse_metadata(body, id_type, provider_id)
        {:ok, metadata}

      {:ok, %{status: 404}} ->
        {:error, Error.not_found("Book not found: #{provider_id}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Fetch failed #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def fetch_images(_config, _provider_id, _opts) do
    # Open Library covers are handled within metadata usually,
    # but we could implement this to fetch all cover sizes/variants.
    # For now, return empty.
    {:ok, %Mydia.Metadata.Structs.ImagesResponse{posters: [], backdrops: [], logos: []}}
  end

  @impl true
  def fetch_season(_config, _provider_id, _season_number, _opts) do
    {:error, Error.invalid_request("Season fetching is not supported for books")}
  end

  @impl true
  def fetch_trending(_config, _opts) do
    {:ok, []}
  end

  defp parse_search_results(%{"docs" => docs}) when is_list(docs) do
    Enum.map(docs, &parse_search_doc/1)
  end

  defp parse_search_results(_), do: []

  defp parse_search_doc(doc) do
    # Extract OLID from key "/works/OL..."
    provider_id =
      case doc["key"] do
        "/works/" <> id -> id
        key -> key
      end

    %SearchResult{
      provider_id: provider_id,
      provider: :open_library,
      title: doc["title"],
      # Open Library usually just has title
      original_title: doc["title"],
      year: doc["first_publish_year"],
      media_type: :book,
      # Sometimes text is available?
      overview: List.first(doc["text"] || []),
      poster_path: get_cover_url(doc["cover_i"]),
      backdrop_path: nil,
      popularity: nil,
      vote_average: nil,
      # Proxy for popularity?
      vote_count: doc["edition_count"]
    }
  end

  defp parse_metadata(body, :isbn, original_id) do
    # Body is like {"ISBN:978..." => {...}}
    # We need to extract the inner object.
    # Ensure format matches key
    key = String.replace_prefix(original_id, "ISBN:", "ISBN:")

    # Open Library API returns keys as requested, e.g. "ISBN:978..."
    # But if we requested just the number, it might be different.
    # The handler uses `bibkeys=ISBN:#{isbn}` so the key should be `ISBN:#{isbn}`.

    # Find the object in the map
    data = Map.get(body, key) || Enum.at(Map.values(body), 0)

    if data do
      # ISBN lookup returns "Book" object (Edition), not Work.
      # It contains "works" link: [{"key": "/works/OL..."}]
      # We might want to fetch the Work details too, but for now let's map what we have.
      map_book_data(data, original_id)
    else
      nil
    end
  end

  defp parse_metadata(body, :olid, provider_id) do
    # Body is the Work object
    map_work_data(body, provider_id)
  end

  defp map_book_data(data, provider_id) do
    %BookMetadata{
      provider_id: provider_id,
      provider: :open_library,
      title: data["title"],
      subtitle: data["subtitle"],
      authors: parse_authors(data["authors"]),
      isbn_10: get_isbn(data, 10),
      isbn_13: get_isbn(data, 13),
      publish_date: data["publish_date"],
      publisher: parse_publisher(data["publishers"]),
      number_of_pages: data["number_of_pages"],
      # Editions usually don't have descriptions, Works do.
      description: nil,
      cover_url: get_cover_url(data["cover"] || data["covers"]),
      genres: parse_subjects(data["subjects"]),
      series_name: nil,
      series_position: nil,
      language: nil,
      identifiers: data["identifiers"]
    }
  end

  defp map_work_data(data, provider_id) do
    %BookMetadata{
      provider_id: provider_id,
      provider: :open_library,
      title: data["title"],
      # Works don't usually have subtitles separate
      subtitle: nil,
      # Works have "authors" as links to Author objects. need to resolve?
      authors: nil,
      # Works don't have ISBNs, Editions do.
      isbn_10: nil,
      isbn_13: nil,
      publish_date: data["first_publish_date"],
      publisher: nil,
      number_of_pages: nil,
      description: parse_description(data["description"]),
      cover_url: get_cover_url(data["covers"]),
      genres: parse_subjects(data["subjects"]),
      series_name: nil,
      series_position: nil,
      language: nil,
      identifiers: nil
    }
  end

  defp parse_authors(nil), do: []

  defp parse_authors(authors) when is_list(authors) do
    Enum.map(authors, fn
      %{"url" => _url, "name" => name} -> name
      %{"name" => name} -> name
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_authors(_), do: []

  defp parse_publisher(nil), do: nil

  defp parse_publisher(publishers) when is_list(publishers) do
    Enum.map(publishers, & &1["name"])
    |> List.first()
  end

  defp parse_publisher(_), do: nil

  defp get_isbn(data, 10) do
    # identifiers: {"isbn_10": ["..."]}
    case get_in(data, ["identifiers", "isbn_10"]) do
      list when is_list(list) -> List.first(list)
      _ -> nil
    end
  end

  defp get_isbn(data, 13) do
    case get_in(data, ["identifiers", "isbn_13"]) do
      list when is_list(list) -> List.first(list)
      _ -> nil
    end
  end

  defp parse_subjects(nil), do: []

  defp parse_subjects(subjects) when is_list(subjects) do
    Enum.map(subjects, &(&1["name"] || &1))
  end

  defp parse_subjects(_), do: []

  defp parse_description(nil), do: nil
  defp parse_description(%{"value" => val}), do: val
  defp parse_description(desc) when is_binary(desc), do: desc
  defp parse_description(_), do: nil

  defp get_cover_url(nil), do: nil
  defp get_cover_url([]), do: nil

  defp get_cover_url([id | _]) when is_integer(id),
    do: "https://covers.openlibrary.org/b/id/#{id}-L.jpg"

  defp get_cover_url(id) when is_integer(id),
    do: "https://covers.openlibrary.org/b/id/#{id}-L.jpg"

  defp get_cover_url(%{"medium" => url}), do: url
  defp get_cover_url(%{"large" => url}), do: url
  defp get_cover_url(_), do: nil
end
