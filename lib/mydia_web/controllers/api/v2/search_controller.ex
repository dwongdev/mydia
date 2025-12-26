defmodule MydiaWeb.Api.V2.SearchController do
  @moduledoc """
  REST API controller for searching media library.

  Provides full-text search across movies and TV shows.
  """

  use MydiaWeb, :controller

  import Ecto.Query, warn: false
  alias Mydia.Repo
  alias Mydia.Media.MediaItem

  @default_limit 20
  @max_limit 100

  @doc """
  Searches media items by title.

  GET /api/v2/search?q=query&limit=20

  Query params:
    - q: Search query (searches title and original_title fields)
    - limit: Maximum number of results (default: 20, max: 100)

  Returns:
    - 200: Search results with matching media items
    - 200: Empty results if no query provided or no matches found
  """
  def index(conn, params) do
    query = Map.get(params, "q", "")
    limit = parse_limit(params["limit"])

    results = search_media_items(query, limit)

    json(conn, %{
      results: Enum.map(results, &serialize_search_result/1),
      total: length(results)
    })
  end

  ## Private Functions

  defp search_media_items("", _limit), do: []

  defp search_media_items(query, limit) when is_binary(query) do
    search_pattern = "%#{query}%"

    MediaItem
    |> where(
      [m],
      ilike(m.title, ^search_pattern) or ilike(m.original_title, ^search_pattern)
    )
    |> order_by([m], asc: m.title)
    |> limit(^limit)
    |> Repo.all()
  end

  defp parse_limit(nil), do: @default_limit
  defp parse_limit(""), do: @default_limit

  defp parse_limit(limit_str) when is_binary(limit_str) do
    case Integer.parse(limit_str) do
      {limit, _} when limit > 0 and limit <= @max_limit -> limit
      {limit, _} when limit > @max_limit -> @max_limit
      _ -> @default_limit
    end
  end

  defp parse_limit(limit) when is_integer(limit) and limit > 0 and limit <= @max_limit,
    do: limit

  defp parse_limit(limit) when is_integer(limit) and limit > @max_limit, do: @max_limit
  defp parse_limit(_), do: @default_limit

  defp serialize_search_result(media_item) do
    %{
      id: media_item.id,
      type: media_item.type,
      title: media_item.title,
      original_title: media_item.original_title,
      year: media_item.year,
      poster_url: extract_poster_url(media_item)
    }
  end

  defp extract_poster_url(%MediaItem{metadata: %{"poster_path" => poster_path}})
       when is_binary(poster_path),
       do: poster_path

  defp extract_poster_url(_), do: nil
end
