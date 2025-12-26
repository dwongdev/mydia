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

  # Relay token secret (required for production)
  relay_token_secret =
    System.get_env("RELAY_TOKEN_SECRET") ||
      if config_env() == :prod do
        raise "RELAY_TOKEN_SECRET environment variable is required in production"
      else
        "dev-secret-change-in-prod"
      end

  config :metadata_relay,
    relay_token_secret: relay_token_secret

  if config_env() == :prod do
    # API keys from environment
    tmdb_api_key = System.get_env("TMDB_API_KEY")
    tvdb_api_key = System.get_env("TVDB_API_KEY")

    config :metadata_relay,
      tmdb_api_key: tmdb_api_key,
      tvdb_api_key: tvdb_api_key
  end
end
