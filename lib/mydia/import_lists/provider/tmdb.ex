defmodule Mydia.ImportLists.Provider.TMDB do
  @moduledoc """
  TMDB list provider for import lists.

  Fetches items from various TMDB curated lists via the metadata-relay service:
  - Trending (movies and TV)
  - Popular (movies and TV)
  - Upcoming movies
  - Now Playing movies
  - On The Air TV shows
  - Airing Today TV shows
  - User-created TMDB lists
  """

  @behaviour Mydia.ImportLists.Provider

  require Logger
  alias Mydia.Metadata.Provider.HTTP
  alias Mydia.ImportLists.ImportList

  @supported_types ~w(
    tmdb_trending
    tmdb_popular
    tmdb_upcoming
    tmdb_now_playing
    tmdb_on_the_air
    tmdb_airing_today
    tmdb_list
  )

  @impl true
  def supports?(type), do: type in @supported_types

  @impl true
  def fetch_items(%ImportList{type: "tmdb_list"} = import_list) do
    config = get_config()
    list_id = extract_list_id(import_list.config)

    case list_id do
      nil ->
        {:error, "No list ID configured"}

      id ->
        fetch_user_list(config, id, import_list.media_type)
    end
  end

  def fetch_items(%ImportList{} = import_list) do
    config = get_config()

    case fetch_from_endpoint(config, import_list.type, import_list.media_type) do
      {:ok, results} ->
        items = Enum.map(results, &parse_result(&1, import_list.media_type))
        {:ok, items}

      {:error, reason} ->
        Logger.error("Failed to fetch TMDB list items",
          type: import_list.type,
          media_type: import_list.media_type,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  ## Private Functions

  defp get_config do
    Mydia.Metadata.default_relay_config()
  end

  # Extract list ID from config - handles both raw ID and full URL
  defp extract_list_id(nil), do: nil

  defp extract_list_id(%{"list_url" => url}) when is_binary(url),
    do: extract_list_id_from_url(url)

  defp extract_list_id(_), do: nil

  defp extract_list_id_from_url(url) do
    cond do
      # Pure numeric ID
      Regex.match?(~r/^\d+$/, url) ->
        url

      # Full TMDB URL like https://www.themoviedb.org/list/12345
      String.contains?(url, "themoviedb.org/list/") ->
        case Regex.run(~r{/list/(\d+)}, url) do
          [_, id] -> id
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp fetch_user_list(config, list_id, media_type) do
    endpoint = "/tmdb/list/#{list_id}"
    params = [language: "en-US"]

    req = HTTP.new_request(config)

    case HTTP.get(req, endpoint, params: params) do
      {:ok, %{status: 200, body: %{"items" => items}}} when is_list(items) ->
        # Filter items by media type and parse them
        filtered_items =
          items
          |> Enum.filter(&matches_media_type?(&1, media_type))
          |> Enum.map(&parse_result(&1, media_type))

        {:ok, filtered_items}

      {:ok, %{status: 200, body: body}} ->
        Logger.warning("Unexpected TMDB list response format", body: inspect(body))
        {:ok, []}

      {:ok, %{status: 404, body: _}} ->
        {:error, "TMDB list not found (ID: #{list_id})"}

      {:ok, %{status: status, body: body}} ->
        {:error, "API returned status #{status}: #{inspect(body)}"}

      {:error, error} ->
        {:error, error}
    end
  end

  # Check if a TMDB item matches the expected media type
  defp matches_media_type?(%{"media_type" => "movie"}, "movie"), do: true
  defp matches_media_type?(%{"media_type" => "tv"}, "tv_show"), do: true
  # If no media_type field, include it (let user decide)
  defp matches_media_type?(%{"media_type" => nil}, _), do: true
  defp matches_media_type?(item, _) when not is_map_key(item, "media_type"), do: true
  defp matches_media_type?(_, _), do: false

  defp fetch_from_endpoint(config, type, media_type) do
    endpoint = build_endpoint(type, media_type)
    params = [language: "en-US", page: 1]

    req = HTTP.new_request(config)

    case HTTP.get(req, endpoint, params: params) do
      {:ok, %{status: 200, body: %{"results" => results}}} when is_list(results) ->
        {:ok, results}

      {:ok, %{status: 200, body: body}} ->
        # Some endpoints might return results directly
        if is_list(body), do: {:ok, body}, else: {:ok, []}

      {:ok, %{status: status, body: body}} ->
        {:error, "API returned status #{status}: #{inspect(body)}"}

      {:error, error} ->
        {:error, error}
    end
  end

  defp build_endpoint("tmdb_trending", "movie"), do: "/tmdb/movies/trending"
  defp build_endpoint("tmdb_trending", "tv_show"), do: "/tmdb/tv/trending"
  defp build_endpoint("tmdb_popular", "movie"), do: "/tmdb/movies/popular"
  defp build_endpoint("tmdb_popular", "tv_show"), do: "/tmdb/tv/popular"
  defp build_endpoint("tmdb_upcoming", "movie"), do: "/tmdb/movies/upcoming"
  defp build_endpoint("tmdb_now_playing", "movie"), do: "/tmdb/movies/now_playing"
  defp build_endpoint("tmdb_on_the_air", "tv_show"), do: "/tmdb/tv/on_the_air"
  defp build_endpoint("tmdb_airing_today", "tv_show"), do: "/tmdb/tv/airing_today"
  # Fallback for invalid combinations
  defp build_endpoint(type, media_type) do
    Logger.warning("Invalid TMDB list type/media_type combination",
      type: type,
      media_type: media_type
    )

    "/tmdb/movies/trending"
  end

  defp parse_result(result, media_type) do
    # Extract year from release_date or first_air_date
    year = extract_year(result)

    %{
      tmdb_id: result["id"],
      title: result["title"] || result["name"],
      year: year,
      poster_path: result["poster_path"],
      media_type: media_type
    }
  end

  defp extract_year(%{"release_date" => date}) when is_binary(date) and byte_size(date) >= 4 do
    case Integer.parse(String.slice(date, 0, 4)) do
      {year, _} -> year
      :error -> nil
    end
  end

  defp extract_year(%{"first_air_date" => date}) when is_binary(date) and byte_size(date) >= 4 do
    case Integer.parse(String.slice(date, 0, 4)) do
      {year, _} -> year
      :error -> nil
    end
  end

  defp extract_year(_), do: nil
end
