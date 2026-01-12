defmodule MetadataRelay.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Create ETS tables before supervision tree for O(1) connection lookups
    create_ets_tables()

    # Determine cache adapter based on REDIS_URL environment variable
    {cache_adapter, cache_opts} = configure_cache()

    # Store the selected adapter in application env
    Application.put_env(:metadata_relay, :cache_adapter, cache_adapter)

    # Build children list with optional OpenSubtitles support
    children =
      [
        # Database repository
        MetadataRelay.Repo,
        # PubSub for Phoenix LiveView and relay
        {Phoenix.PubSub, name: MetadataRelay.PubSub},
        # Cache adapter (Redis or in-memory)
        {cache_adapter, cache_opts},
        # Rate limiter for crash reports
        MetadataRelay.RateLimiter,
        # Relay claim cleanup process
        MetadataRelay.Relay.Cleanup
      ] ++
        maybe_tvdb_auth() ++
        maybe_opensubtitles_auth() ++
        maybe_p2p_relay() ++
        [
          # Phoenix endpoint (serves both API and ErrorTracker dashboard)
          MetadataRelayWeb.Endpoint
        ]

    opts = [strategy: :one_for_one, name: MetadataRelay.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp configure_cache do
    case System.get_env("REDIS_URL") do
      nil ->
        Logger.info("REDIS_URL not set, using in-memory cache")
        {MetadataRelay.Cache.InMemory, []}

      redis_url ->
        Logger.info("REDIS_URL detected, attempting to connect to Redis")

        case parse_redis_url(redis_url) do
          {:ok, opts} ->
            {MetadataRelay.Cache.Redis, opts}

          {:error, reason} ->
            Logger.warning(
              "Failed to parse REDIS_URL: #{inspect(reason)}, falling back to in-memory cache"
            )

            {MetadataRelay.Cache.InMemory, []}
        end
    end
  end

  defp parse_redis_url(url) do
    uri = URI.parse(url)

    case uri do
      %URI{scheme: scheme, host: host, port: port} when scheme in ["redis", "rediss"] ->
        opts = [
          host: host || "localhost",
          port: port || 6379
        ]

        opts =
          if uri.userinfo do
            # Redis URLs can have format redis://[:password@]host:port
            case String.split(uri.userinfo, ":", parts: 2) do
              [password] -> Keyword.put(opts, :password, password)
              [_username, password] -> Keyword.put(opts, :password, password)
            end
          else
            opts
          end

        {:ok, opts}

      _ ->
        {:error, :invalid_redis_url}
    end
  end

  defp maybe_tvdb_auth do
    tvdb_key = System.get_env("TVDB_API_KEY")

    if tvdb_key && tvdb_key != "" && tvdb_key != "test_key" do
      Logger.info("TVDB API key detected, enabling TVDB support")
      [MetadataRelay.TVDB.Auth]
    else
      Logger.warning("TVDB API key not configured or invalid, TVDB support disabled")
      []
    end
  end

  defp maybe_opensubtitles_auth do
    api_key = System.get_env("OPENSUBTITLES_API_KEY")
    username = System.get_env("OPENSUBTITLES_USERNAME")
    password = System.get_env("OPENSUBTITLES_PASSWORD")

    if api_key && username && password do
      Logger.info("OpenSubtitles credentials detected, enabling subtitle support")
      [MetadataRelay.OpenSubtitles.Auth]
    else
      Logger.info("OpenSubtitles credentials not configured, subtitle support disabled")
      []
    end
  end

  defp maybe_p2p_relay do
    if System.get_env("LIBP2P_RELAY_ENABLED") == "true" do
      Logger.info("Libp2p Relay enabled, starting P2P host")
      [MetadataRelay.P2p.Server]
    else
      Logger.info("Libp2p Relay disabled")
      []
    end
  end

  defp create_ets_tables do
    # Create ETS tables for O(1) relay connection lookups
    # These must be created before the supervision tree starts
    Logger.info("Creating ETS tables for relay connection registry")
    MetadataRelay.Relay.ConnectionRegistry.create_table()
    MetadataRelay.Relay.PendingRequests.create_table()
  end
end
