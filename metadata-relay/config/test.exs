import Config

# Test configuration
config :logger, level: :warning

# Disable Phoenix endpoint server in tests
config :metadata_relay, MetadataRelayWeb.Endpoint,
  http: [port: 4002],
  server: false

# Use file-based SQLite database for tests
# In-memory databases don't persist across connections, breaking mix ecto.migrate
config :metadata_relay, MetadataRelay.Repo,
  database: Path.expand("../metadata_relay_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox
