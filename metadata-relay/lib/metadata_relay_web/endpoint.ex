defmodule MetadataRelayWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :metadata_relay

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_metadata_relay_key",
    signing_salt: "error_tracker_salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  # Relay WebSocket endpoints
  # Pass peer_data to get client IP for public URL enrichment
  # 60s timeout allows for 30s heartbeat interval with margin
  socket("/relay/tunnel", MetadataRelayWeb.RelaySocket,
    websocket: [
      timeout: 60_000,
      connect_info: [:peer_data, :x_headers]
    ]
  )

  # Client tunnel socket for Flutter player connections
  # check_origin: false allows cross-origin WebSocket connections from any domain
  # This is required because the player can run from various origins (localhost, production domains)
  socket("/relay/client", MetadataRelayWeb.ClientTunnelSocket,
    websocket: [
      timeout: 60_000,
      check_origin: false
    ]
  )

  # Serve at "/" the static files from "priv/static" directory.
  plug(Plug.Static,
    at: "/",
    from: :metadata_relay,
    gzip: false,
    only: ~w(css js assets fonts images favicon.ico robots.txt)
  )

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)

  # CORS support for browser-based clients
  plug(Corsica,
    origins: "*",
    allow_headers: ["content-type", "authorization", "x-request-id"],
    allow_methods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
  )

  plug(MetadataRelayWeb.Router)
end
