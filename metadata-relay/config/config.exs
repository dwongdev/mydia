import Config

# Configure the application
config :metadata_relay,
  # Default port for HTTP server
  port: 4000,
  # Ecto repository
  ecto_repos: [MetadataRelay.Repo]

# Configure Phoenix endpoint for ErrorTracker dashboard
config :metadata_relay, MetadataRelayWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MetadataRelayWeb.Layouts],
    layout: false
  ],
  pubsub_server: MetadataRelay.PubSub,
  live_view: [signing_salt: "error_tracker_lv_salt"],
  secret_key_base:
    "metadata_relay_secret_key_base_placeholder_needs_to_be_at_least_64_bytes_long_for_security"

# Configure ErrorTracker
config :error_tracker,
  repo: MetadataRelay.Repo,
  otp_app: :metadata_relay,
  enabled: true

# Configure the logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Import environment specific config
import_config "#{config_env()}.exs"
