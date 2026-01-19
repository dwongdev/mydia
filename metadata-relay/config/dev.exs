import Config

# Development configuration
config :logger, :console, format: "[$level] $message\n"

# Enable code reloading for development
config :metadata_relay, MetadataRelayWeb.Endpoint,
  code_reloader: true,
  check_origin: false,
  watchers: []

config :phoenix, :stacktrace_depth, 20
