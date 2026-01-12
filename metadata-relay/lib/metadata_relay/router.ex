defmodule MetadataRelay.Router do
  @moduledoc """
  HTTP router for the metadata relay service.
  """

  use Plug.Router

  alias MetadataRelay.TMDB.Handler
  alias MetadataRelay.TVDB.Handler, as: TVDBHandler
  alias MetadataRelay.Music.Handler, as: MusicHandler
  alias MetadataRelay.OpenLibrary.Handler, as: OpenLibraryHandler
  alias MetadataRelay.OpenSubtitles.Handler, as: SubtitlesHandler
  alias MetadataRelay.Relay.Handler, as: RelayHandler

  plug(Plug.Logger)
  plug(Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: Jason)
  plug(MetadataRelay.Plug.Cache)
  plug(:match)
  plug(:dispatch)

  # Health check endpoint
  get "/health" do
    response = %{
      status: "ok",
      service: "metadata-relay",
      version: MetadataRelay.version()
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response))
  end

  # Cache statistics endpoint
  get "/stats" do
    cache_stats = MetadataRelay.Cache.stats()

    response = %{
      service: "metadata-relay",
      version: MetadataRelay.version(),
      cache: cache_stats
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response))
  end

  # Libp2p relay info endpoint
  # Returns the relay's multiaddr for client bootstrap
  get "/p2p/info" do
    case MetadataRelay.P2p.Server.get_info() do
      {:ok, info} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(info))

      {:error, :not_running} ->
        error_response = %{
          error: "P2P relay not running",
          message: "The libp2p relay server is not enabled or has not started"
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(error_response))
    end
  end

  # TMDB Configuration
  get "/configuration" do
    handle_tmdb_request(conn, fn -> Handler.configuration() end)
  end

  # TMDB Movie Search
  get "/tmdb/movies/search" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.search_movies(params) end)
  end

  # TMDB TV Search
  get "/tmdb/tv/search" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.search_tv(params) end)
  end

  # TMDB Trending Movies (must come before /tmdb/movies/:id)
  get "/tmdb/movies/trending" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.trending_movies(params) end)
  end

  # TMDB Popular Movies
  get "/tmdb/movies/popular" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.popular_movies(params) end)
  end

  # TMDB Upcoming Movies
  get "/tmdb/movies/upcoming" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.upcoming_movies(params) end)
  end

  # TMDB Now Playing Movies
  get "/tmdb/movies/now_playing" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.now_playing_movies(params) end)
  end

  # TMDB Trending TV (must come before /tmdb/tv/shows/:id)
  get "/tmdb/tv/trending" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.trending_tv(params) end)
  end

  # TMDB Popular TV
  get "/tmdb/tv/popular" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.popular_tv(params) end)
  end

  # TMDB On The Air TV
  get "/tmdb/tv/on_the_air" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.on_the_air_tv(params) end)
  end

  # TMDB Airing Today TV
  get "/tmdb/tv/airing_today" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.airing_today_tv(params) end)
  end

  # TMDB User List (must come before /tmdb/movies/:id)
  get "/tmdb/list/:id" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.get_list(id, params) end)
  end

  # TMDB Movie Details
  get "/tmdb/movies/:id" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.get_movie(id, params) end)
  end

  # TMDB TV Show Details
  get "/tmdb/tv/shows/:id" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.get_tv_show(id, params) end)
  end

  # TMDB Movie Images
  get "/tmdb/movies/:id/images" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.get_movie_images(id, params) end)
  end

  # TMDB TV Show Images
  get "/tmdb/tv/shows/:id/images" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.get_tv_images(id, params) end)
  end

  # TMDB TV Season Details
  get "/tmdb/tv/shows/:id/:season" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.get_season(id, season, params) end)
  end

  # TVDB Search
  get "/tvdb/search" do
    params = extract_query_params(conn)
    handle_tvdb_request(conn, fn -> TVDBHandler.search(params) end)
  end

  # TVDB Series Details
  get "/tvdb/series/:id" do
    params = extract_query_params(conn)
    handle_tvdb_request(conn, fn -> TVDBHandler.get_series(id, params) end)
  end

  # TVDB Series Extended Details
  get "/tvdb/series/:id/extended" do
    params = extract_query_params(conn)
    handle_tvdb_request(conn, fn -> TVDBHandler.get_series_extended(id, params) end)
  end

  # TVDB Series Episodes
  get "/tvdb/series/:id/episodes" do
    params = extract_query_params(conn)
    handle_tvdb_request(conn, fn -> TVDBHandler.get_series_episodes(id, params) end)
  end

  # TVDB Season Details
  get "/tvdb/seasons/:id" do
    params = extract_query_params(conn)
    handle_tvdb_request(conn, fn -> TVDBHandler.get_season(id, params) end)
  end

  # TVDB Season Extended Details
  get "/tvdb/seasons/:id/extended" do
    params = extract_query_params(conn)
    handle_tvdb_request(conn, fn -> TVDBHandler.get_season_extended(id, params) end)
  end

  # TVDB Episode Details
  get "/tvdb/episodes/:id" do
    params = extract_query_params(conn)
    handle_tvdb_request(conn, fn -> TVDBHandler.get_episode(id, params) end)
  end

  # TVDB Episode Extended Details
  get "/tvdb/episodes/:id/extended" do
    params = extract_query_params(conn)
    handle_tvdb_request(conn, fn -> TVDBHandler.get_episode_extended(id, params) end)
  end

  # TVDB Artwork
  get "/tvdb/artwork/:id" do
    params = extract_query_params(conn)
    handle_tvdb_request(conn, fn -> TVDBHandler.get_artwork(id, params) end)
  end

  # Crash Report Ingestion
  post "/crashes/report" do
    handle_crash_report(conn)
  end

  # Subtitle Search
  post "/api/v1/subtitles/search" do
    params = extract_body_params(conn)
    handle_subtitles_request(conn, fn -> SubtitlesHandler.search(params) end)
  end

  # Subtitle Download URL
  get "/api/v1/subtitles/download-url/:id" do
    handle_subtitles_request(conn, fn -> SubtitlesHandler.get_download_url(id) end)
  end

  # Music Search
  get "/music/search" do
    params = extract_query_params(conn)
    handle_music_request(conn, fn -> MusicHandler.search(params) end)
  end

  # Music Artist Details
  get "/music/artist/:id" do
    params = extract_query_params(conn)
    handle_music_request(conn, fn -> MusicHandler.get_artist(id, params) end)
  end

  # Music Release Details
  get "/music/release/:id" do
    params = extract_query_params(conn)
    handle_music_request(conn, fn -> MusicHandler.get_release(id, params) end)
  end

  # Music Release Group Details
  get "/music/release-group/:id" do
    params = extract_query_params(conn)
    handle_music_request(conn, fn -> MusicHandler.get_release_group(id, params) end)
  end

  # Music Recording Details
  get "/music/recording/:id" do
    params = extract_query_params(conn)
    handle_music_request(conn, fn -> MusicHandler.get_recording(id, params) end)
  end

  # Music Cover Art
  get "/music/cover/:id" do
    handle_image_request(conn, fn -> MusicHandler.get_cover_art(id) end)
  end

  # OpenLibrary ISBN Lookup
  get "/openlibrary/isbn/:isbn" do
    params = extract_query_params(conn)
    handle_openlibrary_request(conn, fn -> OpenLibraryHandler.get_by_isbn(isbn, params) end)
  end

  # OpenLibrary Search
  get "/openlibrary/search" do
    params = extract_query_params(conn)
    handle_openlibrary_request(conn, fn -> OpenLibraryHandler.search(params) end)
  end

  # OpenLibrary Work Details
  get "/openlibrary/works/:id" do
    params = extract_query_params(conn)
    handle_openlibrary_request(conn, fn -> OpenLibraryHandler.get_work(id, params) end)
  end

  # OpenLibrary Author Details
  get "/openlibrary/authors/:id" do
    params = extract_query_params(conn)
    handle_openlibrary_request(conn, fn -> OpenLibraryHandler.get_author(id, params) end)
  end

  # ============================================================================
  # Relay API - Remote Access
  # ============================================================================

  # Register new instance
  post "/relay/instances" do
    with :ok <- check_relay_rate_limit(conn, limit: 10, window_ms: 60_000) do
      handle_relay_request(conn, fn -> RelayHandler.register_instance(conn.body_params) end)
    else
      {:error, :rate_limited} -> send_rate_limited(conn, 60)
    end
  end

  # Update instance heartbeat/presence
  put "/relay/instances/:id/heartbeat" do
    with {:ok, _instance_id} <- verify_relay_auth(conn, id) do
      handle_relay_request(conn, fn ->
        RelayHandler.update_heartbeat(id, conn.body_params)
      end)
    else
      {:error, :unauthorized} ->
        send_unauthorized(conn)
    end
  end

  # Create claim code
  post "/relay/instances/:id/claim" do
    with {:ok, _instance_id} <- verify_relay_auth(conn, id) do
      handle_relay_request(conn, fn ->
        RelayHandler.create_claim(id, conn.body_params)
      end)
    else
      {:error, :unauthorized} ->
        send_unauthorized(conn)
    end
  end

  # Redeem claim code
  post "/relay/claim/:code" do
    with :ok <- check_relay_rate_limit(conn, limit: 5, window_ms: 60_000) do
      handle_relay_request(conn, fn -> RelayHandler.redeem_claim(code) end)
    else
      {:error, :rate_limited} -> send_rate_limited(conn, 60)
    end
  end

  # Consume claim (after successful pairing)
  post "/relay/claim/consume" do
    with {:ok, instance_id} <- verify_relay_auth_from_claim(conn) do
      handle_relay_request(conn, fn ->
        RelayHandler.consume_claim(instance_id, conn.body_params)
      end)
    else
      {:error, :unauthorized} ->
        send_unauthorized(conn)
    end
  end

  # Get connection info
  get "/relay/instances/:id/connect" do
    with :ok <- check_relay_rate_limit(conn, limit: 30, window_ms: 60_000) do
      handle_relay_request(conn, fn -> RelayHandler.get_connection_info(id) end)
    else
      {:error, :rate_limited} -> send_rate_limited(conn, 60)
    end
  end

  # 404 catch-all
  match _ do
    send_resp(conn, 404, "Not found")
  end

  # Private helpers

  defp handle_tmdb_request(conn, handler_fn) do
    case handler_fn.() do
      {:ok, body} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(body))

      {:error, {:http_error, status, body}} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))

      {:error, reason} ->
        error_response = %{
          error: "Internal server error",
          message: inspect(reason)
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(error_response))
    end
  end

  defp handle_tvdb_request(conn, handler_fn) do
    case handler_fn.() do
      {:ok, body} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(body))

      {:error, {:http_error, status, body}} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))

      {:error, {:authentication_failed, reason}} ->
        error_response = %{
          error: "Authentication failed",
          message: "Failed to authenticate with TVDB: #{inspect(reason)}"
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(error_response))

      {:error, reason} ->
        error_response = %{
          error: "Internal server error",
          message: inspect(reason)
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(error_response))
    end
  end

  defp extract_query_params(conn) do
    conn.query_params
    |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
  end

  defp extract_body_params(conn) do
    conn.body_params
    |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
    |> Map.new()
  end

  defp handle_crash_report(conn) do
    # Check rate limit first (by IP address)
    client_ip = get_client_ip(conn)

    case MetadataRelay.RateLimiter.check_rate_limit(client_ip) do
      {:error, :rate_limited} ->
        error_response = %{
          error: "Too many requests",
          message: "Rate limit exceeded. Please try again later."
        }

        conn
        |> put_resp_header("retry-after", "60")
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(error_response))

      {:ok, _remaining} ->
        # Rate limit passed - process the crash report
        process_crash_report(conn)
    end
  end

  defp get_client_ip(conn) do
    # Get the client IP from the connection
    # Check X-Forwarded-For header first (for proxied requests)
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded
        |> String.split(",")
        |> List.first()
        |> String.trim()

      [] ->
        # Fall back to remote_ip
        conn.remote_ip
        |> :inet.ntoa()
        |> to_string()
    end
  end

  defp process_crash_report(conn) do
    with {:ok, body} <- validate_crash_report(conn.body_params),
         {:ok, _occurrence} <- store_crash_report(body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(201, Jason.encode!(%{status: "created", message: "Crash report received"}))
    else
      {:error, :invalid_json} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{error: "Invalid JSON", message: "Request body must be valid JSON"})
        )

      {:error, {:validation, errors}} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Validation failed", errors: errors}))

      {:error, reason} ->
        error_response = %{
          error: "Internal server error",
          message: "Failed to store crash report: #{inspect(reason)}"
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(error_response))
    end
  end

  defp validate_crash_report(params) when is_map(params) do
    required_fields = ["error_type", "error_message", "stacktrace"]

    errors =
      required_fields
      |> Enum.reject(&Map.has_key?(params, &1))
      |> Enum.map(&"Missing required field: #{&1}")

    # Validate stacktrace is a list
    stacktrace_errors =
      case Map.get(params, "stacktrace") do
        st when is_list(st) -> []
        _ -> ["stacktrace must be a list"]
      end

    all_errors = errors ++ stacktrace_errors

    if all_errors == [] do
      {:ok, params}
    else
      {:error, {:validation, all_errors}}
    end
  end

  defp validate_crash_report(_), do: {:error, :invalid_json}

  defp store_crash_report(body) do
    # Create a runtime error from the crash report data
    error_type = Map.get(body, "error_type", "RuntimeError")
    error_message = Map.get(body, "error_message", "Unknown error")

    # Reconstruct stacktrace from the crash report
    stacktrace =
      body
      |> Map.get("stacktrace", [])
      |> Enum.map(&parse_stacktrace_entry/1)
      |> Enum.filter(& &1)

    # Create context from additional metadata
    context = %{
      version: Map.get(body, "version"),
      environment: Map.get(body, "environment"),
      occurred_at: Map.get(body, "occurred_at"),
      metadata: Map.get(body, "metadata", %{})
    }

    # Create exception struct
    exception = %RuntimeError{message: "#{error_type}: #{error_message}"}

    # Report to ErrorTracker
    case ErrorTracker.report(exception, stacktrace, context) do
      :noop ->
        {:error, :error_tracker_disabled}

      occurrence ->
        {:ok, occurrence}
    end
  end

  defp parse_stacktrace_entry(%{"file" => file, "line" => line, "function" => function}) do
    # Convert crash report format to Elixir stacktrace format
    # Format: {module, function, arity, [file: path, line: number]}
    location = build_location(file, line)
    {String.to_atom(function), 0, location}
  end

  defp parse_stacktrace_entry(%{"file" => file, "line" => line}) do
    # Minimal format without function
    location = build_location(file, line)
    {:unknown, 0, location}
  end

  defp parse_stacktrace_entry(_), do: nil

  defp build_location(nil, nil), do: []
  defp build_location(nil, line), do: [line: line]
  defp build_location(file, nil), do: [file: String.to_charlist(file)]
  defp build_location(file, line), do: [file: String.to_charlist(file), line: line]

  defp handle_subtitles_request(conn, handler_fn) do
    case handler_fn.() do
      {:ok, body} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(body))

      {:error, :not_configured} ->
        error_response = %{
          error: "Service not configured",
          message:
            "OpenSubtitles integration is not configured. Please set OPENSUBTITLES_API_KEY, OPENSUBTITLES_USERNAME, and OPENSUBTITLES_PASSWORD environment variables."
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(error_response))

      {:error, {:rate_limited, retry_after}} ->
        error_response = %{
          error: "Too many requests",
          message: "Rate limit exceeded. Please try again later."
        }

        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(error_response))

      {:error, {:http_error, status, body}} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))

      {:error, {:authentication_failed, reason}} ->
        error_response = %{
          error: "Authentication failed",
          message: "Failed to authenticate with OpenSubtitles: #{inspect(reason)}"
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(error_response))

      {:error, reason} ->
        error_response = %{
          error: "Internal server error",
          message: inspect(reason)
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(error_response))
    end
  end

  defp handle_music_request(conn, handler_fn) do
    case handler_fn.() do
      {:ok, body} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(body))

      {:error, {:http_error, status, body}} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))

      {:error, reason} ->
        error_response = %{
          error: "Internal server error",
          message: inspect(reason)
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(error_response))
    end
  end

  defp handle_openlibrary_request(conn, handler_fn) do
    case handler_fn.() do
      {:ok, body} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(body))

      {:error, {:http_error, status, body}} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))

      {:error, reason} ->
        error_response = %{
          error: "Internal server error",
          message: inspect(reason)
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(error_response))
    end
  end

  defp handle_image_request(conn, handler_fn) do
    case handler_fn.() do
      {:ok, body} ->
        conn
        |> put_resp_content_type("image/jpeg")
        |> send_resp(200, body)

      {:error, :not_found} ->
        send_resp(conn, 404, "Not found")

      {:error, {:http_error, status}} ->
        send_resp(conn, status, "Upstream error")

      {:error, reason} ->
        send_resp(conn, 500, inspect(reason))
    end
  end

  # Relay request handler
  defp handle_relay_request(conn, handler_fn) do
    case handler_fn.() do
      {:ok, body} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(body))

      {:error, :not_found} ->
        error_response = %{error: "Not found", message: "Resource not found"}

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(error_response))

      {:error, {:validation, message}} ->
        error_response = %{error: "Validation error", message: message}

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(error_response))

      {:error, reason} ->
        error_response = %{error: "Internal server error", message: inspect(reason)}

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(error_response))
    end
  end

  # Verify relay authentication token
  defp verify_relay_auth(conn, expected_instance_id) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case MetadataRelay.Relay.verify_instance_token(token) do
          {:ok, instance_id} when instance_id == expected_instance_id ->
            {:ok, instance_id}

          {:ok, _other_instance_id} ->
            {:error, :unauthorized}

          {:error, _reason} ->
            {:error, :unauthorized}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  # Verify relay authentication token without checking instance_id
  # Returns the instance_id from the token for further validation
  defp verify_relay_auth_from_claim(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case MetadataRelay.Relay.verify_instance_token(token) do
          {:ok, instance_id} ->
            {:ok, instance_id}

          {:error, _reason} ->
            {:error, :unauthorized}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  defp send_unauthorized(conn) do
    error_response = %{error: "Unauthorized", message: "Invalid or missing authentication token"}

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(error_response))
  end

  # Rate limiting helpers

  defp check_relay_rate_limit(conn, opts) do
    client_ip = get_client_ip(conn)
    # Normalize path to group all similar requests together
    normalized_path = normalize_relay_path(conn.request_path)
    key = "relay:#{normalized_path}:#{client_ip}"

    case MetadataRelay.RateLimiter.check_rate_limit(key, opts) do
      {:ok, _remaining} -> :ok
      {:error, :rate_limited} -> {:error, :rate_limited}
    end
  end

  defp normalize_relay_path("/relay/instances/" <> rest) do
    case String.split(rest, "/") do
      [_id, "connect"] -> "/relay/instances/:id/connect"
      _ -> "/relay/instances"
    end
  end

  defp normalize_relay_path("/relay/claim/" <> _code) do
    "/relay/claim/:code"
  end

  defp normalize_relay_path(path), do: path

  defp send_rate_limited(conn, retry_after_seconds) do
    error_response = %{
      error: "rate_limited",
      message: "Too many requests. Please try again later.",
      retry_after: retry_after_seconds
    }

    conn
    |> put_resp_header("retry-after", to_string(retry_after_seconds))
    |> put_resp_content_type("application/json")
    |> send_resp(429, Jason.encode!(error_response))
  end
end
