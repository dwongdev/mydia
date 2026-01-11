import Config

# Runtime configuration loaded at application start
# This is where environment variables are read

# Skip runtime configuration for test environment (handled in test.exs)
if config_env() != :test do
  # Database configuration (all environments except test)
  db_path = System.get_env("SQLITE_DB_PATH") || "./metadata_relay.db"

  config :metadata_relay, MetadataRelay.Repo,
    database: db_path,
    pool_size: 5

  # Phoenix endpoint port configuration (serves both API and dashboard)
  port = String.to_integer(System.get_env("PORT") || "4001")

  config :metadata_relay, MetadataRelayWeb.Endpoint,
    http: [port: port],
    server: true

  if config_env() == :prod do
    # API keys from environment
    tmdb_api_key = System.get_env("TMDB_API_KEY")
    tvdb_api_key = System.get_env("TVDB_API_KEY")

    config :metadata_relay,
      tmdb_api_key: tmdb_api_key,
      tvdb_api_key: tvdb_api_key

    # TURN Server configuration
    # When TURN_ENABLED=true, the integrated TURN server is started
    # and TURN_URI is auto-generated. Otherwise, TURN_URI points to external Coturn.
    turn_enabled = System.get_env("TURN_ENABLED") == "true"
    turn_secret = System.get_env("TURN_SECRET")
    turn_port = String.to_integer(System.get_env("TURN_PORT") || "3478")
    turn_public_ip = System.get_env("TURN_PUBLIC_IP")

    # Build TURN URI based on configuration
    turn_uri =
      cond do
        # Integrated TURN server enabled - use public IP
        turn_enabled && turn_public_ip && turn_public_ip != "" ->
          "turn:#{turn_public_ip}:#{turn_port}"

        # External TURN server specified
        external_uri = System.get_env("TURN_URI") ->
          external_uri

        # No TURN configured
        true ->
          nil
      end

    config :metadata_relay,
      turn_enabled: turn_enabled,
      turn_uri: turn_uri,
      turn_secret: turn_secret,
      turn_port: turn_port,
      turn_public_ip: turn_public_ip,
      turn_realm: System.get_env("TURN_REALM") || "metadata-relay",
      turn_min_port: String.to_integer(System.get_env("TURN_MIN_PORT") || "49152"),
      turn_max_port: String.to_integer(System.get_env("TURN_MAX_PORT") || "65535")
  end
end
