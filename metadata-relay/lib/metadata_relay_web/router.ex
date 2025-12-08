defmodule MetadataRelayWeb.Router do
  use Phoenix.Router
  use ErrorTracker.Web, :router

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {MetadataRelayWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  # ErrorTracker dashboard
  scope "/" do
    pipe_through(:browser)
    error_tracker_dashboard("/errors")
  end

  # Forward all other requests to the API router
  forward("/", MetadataRelay.Router)
end
