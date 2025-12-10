defmodule Mydia.Metadata.Provider.Relay do
  @moduledoc """
  Metadata provider adapter for metadata-relay service.

  This adapter interfaces with the self-hosted metadata-relay service
  (https://metadata-relay.fly.dev) which acts as a caching proxy for TMDB and TVDB APIs.
  Using the relay provides several benefits:

    * No API key required for basic usage
    * Built-in caching reduces redundant API calls
    * Rate limit protection from the relay's pooled quotas
    * Lower latency for frequently requested metadata

  ## Configuration

  The relay provider can be configured with custom relay endpoints or uses the default
  from `Mydia.Metadata.default_relay_config()`:

      config = %{
        type: :metadata_relay,
        base_url: "https://metadata-relay.fly.dev",
        options: %{
          language: "en-US",
          include_adult: false,
          timeout: 30_000
        }
      }

  ## Usage

      # Search for movies
      {:ok, results} = Relay.search(config, "The Matrix", media_type: :movie)

      # Fetch detailed metadata
      {:ok, metadata} = Relay.fetch_by_id(config, "603", media_type: :movie)

      # Fetch images
      {:ok, images} = Relay.fetch_images(config, "603", media_type: :movie)

      # Fetch TV season (for TV shows)
      {:ok, season} = Relay.fetch_season(config, "1396", 1)

  ## Relay Endpoints

  The relay provides endpoints for both TMDB and TVDB:
    * `/tmdb/movies/search` - Search movies via TMDB
    * `/tmdb/tv/search` - Search TV shows via TMDB
    * `/tmdb/movies/{id}` - Get movie details from TMDB
    * `/tmdb/tv/shows/{id}` - Get TV show details from TMDB
    * `/tmdb/movies/{id}/images` - Get movie images from TMDB
    * `/tmdb/tv/shows/{id}/images` - Get TV show images from TMDB
    * `/tmdb/tv/shows/{id}/{season_number}` - Get TV season details from TMDB

  ## Image URLs

  The relay returns relative image paths (e.g., "/poster.jpg") which need to be
  prefixed with the TMDB image base URL. For TMDB images, use:

      https://image.tmdb.org/t/p/w500/poster.jpg (500px width)
      https://image.tmdb.org/t/p/original/poster.jpg (original size)

  Available sizes: w92, w154, w185, w342, w500, w780, original
  """

  @behaviour Mydia.Metadata.Provider

  alias Mydia.Metadata.Provider.{Error, HTTP}

  alias Mydia.Metadata.Structs.{
    SearchResult,
    MediaMetadata,
    SeasonData,
    ImagesResponse
  }

  @default_language "en-US"

  @impl true
  def test_connection(config) do
    req = HTTP.new_request(config)

    case HTTP.get(req, "/configuration") do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, %{status: "ok", provider: "metadata_relay"}}

      {:ok, %{status: status}} ->
        {:error, Error.connection_failed("Relay returned status #{status}")}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def search(config, query, opts \\ []) do
    when_valid_query(query, fn ->
      media_type = Keyword.get(opts, :media_type)
      year = Keyword.get(opts, :year)
      language = Keyword.get(opts, :language, @default_language)
      include_adult = Keyword.get(opts, :include_adult, false)
      page = Keyword.get(opts, :page, 1)

      endpoint = search_endpoint(media_type)

      params =
        [
          query: query,
          language: language,
          include_adult: include_adult,
          page: page
        ]
        |> maybe_add_year(year, media_type)

      req = HTTP.new_request(config)

      case HTTP.get(req, endpoint, params: params) do
        {:ok, %{status: 200, body: body}} ->
          results = parse_search_results(body, media_type)
          {:ok, results}

        {:ok, %{status: status, body: body}} ->
          {:error, Error.api_error("Search failed with status #{status}", %{body: body})}

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  @impl true
  def fetch_by_id(config, provider_id, opts \\ []) do
    media_type = Keyword.get(opts, :media_type, :movie)
    provider = Keyword.get(opts, :provider)

    # Route to TVDB-specific fetch if provider is :tvdb
    if provider == :tvdb do
      fetch_tvdb_by_id(config, provider_id, opts)
    else
      fetch_tmdb_by_id(config, provider_id, media_type, opts)
    end
  end

  # Fetch from TMDB (default behavior)
  defp fetch_tmdb_by_id(config, provider_id, media_type, opts) do
    language = Keyword.get(opts, :language, @default_language)
    append = Keyword.get(opts, :append_to_response, ["credits", "alternative_titles", "videos"])

    endpoint = build_details_endpoint(media_type, provider_id)

    params = [
      language: language,
      append_to_response: Enum.join(append, ",")
    ]

    req = HTTP.new_request(config)

    case HTTP.get(req, endpoint, params: params) do
      {:ok, %{status: 200, body: body}} ->
        metadata = parse_metadata(body, media_type, provider_id)
        {:ok, metadata}

      {:ok, %{status: 404}} ->
        {:error, Error.not_found("Media not found: #{provider_id}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Fetch failed with status #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  # Fetch from TVDB
  defp fetch_tvdb_by_id(config, provider_id, opts) do
    media_type = Keyword.get(opts, :media_type, :tv_show)

    # Use extended endpoint to get more details including seasons
    endpoint = "/tvdb/series/#{provider_id}/extended"

    req = HTTP.new_request(config)

    case HTTP.get(req, endpoint, params: []) do
      {:ok, %{status: 200, body: body}} ->
        # TVDB wraps response in "data" key
        data = body["data"] || body
        # Transform TVDB response to TMDB-like format for parsing
        transformed = transform_tvdb_to_tmdb_format(data, media_type)
        metadata = parse_metadata(transformed, media_type, provider_id)
        # Override provider to :tvdb
        metadata = %{metadata | provider: :tvdb}
        {:ok, metadata}

      {:ok, %{status: 404}} ->
        {:error, Error.not_found("TVDB series not found: #{provider_id}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("TVDB fetch failed with status #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  # Transform TVDB API response to match TMDB format for consistent parsing
  defp transform_tvdb_to_tmdb_format(data, _media_type) when is_map(data) do
    # Extract year from firstAired date or year field
    year = extract_tvdb_year(data)

    # Transform seasons if present
    seasons = transform_tvdb_seasons(data["seasons"])

    # Transform genres
    genres = transform_tvdb_genres(data["genres"])

    # Build TMDB-like response
    %{
      "id" => data["id"],
      "name" => data["name"],
      "original_name" => data["originalName"] || data["name"],
      "overview" => data["overview"],
      "first_air_date" => data["firstAired"],
      "last_air_date" => data["lastAired"],
      "status" => get_in(data, ["status", "name"]),
      "poster_path" => transform_tvdb_image(data["image"]),
      "backdrop_path" => transform_tvdb_artwork(data["artworks"], "background"),
      "genres" => genres,
      "popularity" => data["score"],
      "vote_average" => data["score"],
      "number_of_seasons" => length(seasons),
      "number_of_episodes" => data["episodes"] |> List.wrap() |> length(),
      "in_production" => get_in(data, ["status", "name"]) == "Continuing",
      "seasons" => seasons,
      # Include year for compatibility
      "year" => year,
      # Classification fields for category auto-detection
      "origin_country" => transform_tvdb_origin_country(data["originalCountry"]),
      "original_language" => data["originalLanguage"]
    }
  end

  defp transform_tvdb_to_tmdb_format(data, _media_type), do: data

  defp extract_tvdb_year(%{"year" => year}) when is_binary(year) do
    case Integer.parse(year) do
      {y, _} -> y
      :error -> nil
    end
  end

  defp extract_tvdb_year(%{"firstAired" => first_aired}) when is_binary(first_aired) do
    case String.split(first_aired, "-") do
      [year | _] ->
        case Integer.parse(year) do
          {y, _} -> y
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_tvdb_year(_), do: nil

  defp transform_tvdb_seasons(nil), do: []

  defp transform_tvdb_seasons(seasons) when is_list(seasons) do
    seasons
    |> Enum.filter(fn s -> s["type"]["type"] == "official" end)
    |> Enum.map(fn s ->
      %{
        "id" => s["id"],
        "season_number" => s["number"],
        "name" => s["name"] || "Season #{s["number"]}",
        "overview" => s["overview"],
        "poster_path" => transform_tvdb_image(s["image"]),
        "air_date" => nil,
        "episode_count" => s["episodeCount"] || 0
      }
    end)
  end

  defp transform_tvdb_seasons(_), do: []

  defp transform_tvdb_genres(nil), do: []

  defp transform_tvdb_genres(genres) when is_list(genres) do
    Enum.map(genres, fn g ->
      %{"id" => g["id"], "name" => g["name"]}
    end)
  end

  defp transform_tvdb_genres(_), do: []

  # TVDB returns originalCountry as a string, convert to list for consistency with TMDB
  defp transform_tvdb_origin_country(nil), do: []
  defp transform_tvdb_origin_country(country) when is_binary(country), do: [country]
  defp transform_tvdb_origin_country(countries) when is_list(countries), do: countries
  defp transform_tvdb_origin_country(_), do: []

  # TVDB images are full URLs or relative paths
  defp transform_tvdb_image(nil), do: nil

  defp transform_tvdb_image(url) when is_binary(url) do
    # If it's already a full URL, return as-is
    # The metadata system will handle it appropriately
    url
  end

  defp transform_tvdb_image(_), do: nil

  # Extract specific artwork type from artworks list
  defp transform_tvdb_artwork(nil, _type), do: nil

  defp transform_tvdb_artwork(artworks, type) when is_list(artworks) do
    artwork =
      Enum.find(artworks, fn
        # Handle artwork as a map with type info
        %{"type" => type_info} when is_map(type_info) ->
          type_info["name"] == type

        %{"type" => artwork_type} when is_binary(artwork_type) ->
          artwork_type == type

        # Skip non-map entries (e.g., integer IDs)
        _ ->
          false
      end)

    case artwork do
      %{"image" => image} -> image
      %{"url" => url} -> url
      _ -> nil
    end
  end

  defp transform_tvdb_artwork(_, _), do: nil

  @impl true
  def fetch_images(config, provider_id, opts \\ []) do
    media_type = Keyword.get(opts, :media_type, :movie)
    language = Keyword.get(opts, :language)
    include_image_language = Keyword.get(opts, :include_image_language)

    endpoint = build_images_endpoint(media_type, provider_id)

    params =
      []
      |> maybe_add_param(:language, language)
      |> maybe_add_param(:include_image_language, include_image_language)

    req = HTTP.new_request(config)

    case HTTP.get(req, endpoint, params: params) do
      {:ok, %{status: 200, body: body}} ->
        images = parse_images(body)
        {:ok, images}

      {:ok, %{status: 404}} ->
        {:error, Error.not_found("Media not found: #{provider_id}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Fetch images failed with status #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def fetch_season(config, provider_id, season_number, opts \\ []) do
    language = Keyword.get(opts, :language, @default_language)

    endpoint = "/tmdb/tv/shows/#{provider_id}/#{season_number}"
    params = [language: language]

    req = HTTP.new_request(config)

    case HTTP.get(req, endpoint, params: params) do
      {:ok, %{status: 200, body: body}} ->
        season = parse_season(body)
        {:ok, season}

      {:ok, %{status: 404}} ->
        {:error, Error.not_found("Season not found: #{provider_id}/#{season_number}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Fetch season failed with status #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def fetch_trending(config, opts \\ []) do
    media_type = Keyword.get(opts, :media_type)
    language = Keyword.get(opts, :language, @default_language)
    page = Keyword.get(opts, :page, 1)

    endpoint = build_trending_endpoint(media_type)

    params = [
      language: language,
      page: page
    ]

    req = HTTP.new_request(config)

    case HTTP.get(req, endpoint, params: params) do
      {:ok, %{status: 200, body: body}} ->
        results = parse_search_results(body, media_type)
        {:ok, results}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Fetch trending failed with status #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  ## Private Functions

  defp when_valid_query(query, callback) when is_binary(query) and byte_size(query) > 0 do
    callback.()
  end

  defp when_valid_query(_query, _callback) do
    {:error, Error.invalid_request("Query must be a non-empty string")}
  end

  defp search_endpoint(nil), do: "/tmdb/movies/search"
  defp search_endpoint(:movie), do: "/tmdb/movies/search"
  defp search_endpoint(:tv_show), do: "/tmdb/tv/search"

  defp build_details_endpoint(:movie, id), do: "/tmdb/movies/#{id}"
  defp build_details_endpoint(:tv_show, id), do: "/tmdb/tv/shows/#{id}"

  defp build_images_endpoint(:movie, id), do: "/tmdb/movies/#{id}/images"
  defp build_images_endpoint(:tv_show, id), do: "/tmdb/tv/shows/#{id}/images"

  defp build_trending_endpoint(:movie), do: "/tmdb/movies/trending"
  defp build_trending_endpoint(:tv_show), do: "/tmdb/tv/trending"
  defp build_trending_endpoint(_), do: "/tmdb/movies/trending"

  defp maybe_add_year(params, nil, _media_type), do: params
  defp maybe_add_year(params, year, :movie), do: params ++ [year: year]
  defp maybe_add_year(params, year, :tv_show), do: params ++ [first_air_date_year: year]
  defp maybe_add_year(params, _year, _media_type), do: params

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: params ++ [{key, value}]

  defp parse_search_results(%{"results" => results}, media_type) when is_list(results) do
    Enum.map(results, &parse_search_result(&1, media_type))
  end

  defp parse_search_results(_, _media_type), do: []

  defp parse_search_result(result, media_type) do
    # Pass media_type from search options to override API response's media_type
    # This is needed because endpoint-specific searches (e.g., /tmdb/tv/search)
    # don't include media_type in each result
    SearchResult.from_api_response(result, media_type: media_type)
  end

  defp parse_metadata(data, media_type, provider_id) do
    MediaMetadata.from_api_response(data, media_type, provider_id)
  end

  defp parse_images(data) do
    ImagesResponse.from_api_response(data)
  end

  defp parse_season(data) do
    SeasonData.from_api_response(data)
  end
end
