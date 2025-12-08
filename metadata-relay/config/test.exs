import Config

# Test configuration
config :logger, level: :warning

# Disable Phoenix endpoint server in tests
config :metadata_relay, MetadataRelayWeb.Endpoint,
  http: [port: 4002],
  server: false

# Use in-memory database for tests
config :metadata_relay, MetadataRelay.Repo,
  database: ":memory:",
  pool_size: 1
