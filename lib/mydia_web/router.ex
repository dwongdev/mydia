defmodule MydiaWeb.Router do
  use MydiaWeb, :router
  use ErrorTracker.Web, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MydiaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
  end

  # Base graphql pipeline - authentication handled separately
  pipeline :graphql do
    plug :accepts, ["json"]
    plug :fetch_session
  end

  # Builds Absinthe context after authentication
  # Must run AFTER api_auth so Guardian has the current_user
  pipeline :graphql_context do
    plug MydiaWeb.Plugs.AbsintheContext
  end

  # Authentication pipeline - verifies JWT tokens from session or header
  pipeline :auth do
    plug MydiaWeb.Plugs.AuthPipeline
  end

  # Require authenticated user
  pipeline :require_authenticated do
    plug MydiaWeb.Plugs.EnsureAuthenticated
  end

  # Require admin role
  pipeline :require_admin do
    plug MydiaWeb.Plugs.EnsureRole, :admin
  end

  # API authentication pipeline - supports both JWT and API keys
  pipeline :api_auth do
    plug MydiaWeb.Plugs.AuthPipeline
    plug MydiaWeb.Plugs.ApiAuth
  end

  # Health check endpoint (no authentication required)
  scope "/", MydiaWeb do
    pipe_through :api

    get "/health", HealthController, :check
  end

  # First-time setup (no authentication required)
  scope "/", MydiaWeb do
    pipe_through :browser

    live "/setup", FirstTimeSetupLive.Index, :index
  end

  # Authentication routes
  scope "/auth", MydiaWeb do
    pipe_through :browser

    # Local authentication
    get "/login", SessionController, :new
    get "/local/login", SessionController, :new
    post "/local/login", SessionController, :create

    # Auto-login (for first-time setup)
    get "/auto-login", AuthController, :auto_login

    # OIDC authentication
    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
    post "/:provider/callback", AuthController, :callback

    # Logout
    get "/logout", AuthController, :logout
  end

  # Flutter player web app (authenticated)
  scope "/", MydiaWeb do
    pipe_through [:browser, :auth, :require_authenticated]

    get "/player", PlayerController, :index
    get "/player/*path", PlayerController, :index
  end

  # Authenticated LiveView routes
  scope "/", MydiaWeb do
    pipe_through [:browser, :auth, :require_authenticated]

    live_session :authenticated,
      on_mount: [
        {MydiaWeb.Live.UserAuth, :ensure_authenticated},
        {MydiaWeb.Live.UserAuth, :load_navigation_data}
      ] do
      live "/", DashboardLive.Index, :index
      live "/media", MediaLive.Index, :index
      live "/media/:id", MediaLive.Show, :show
      live "/movies", MediaLive.Index, :movies
      live "/movies/:id", MediaLive.Show, :show
      live "/tv", MediaLive.Index, :tv_shows
      live "/tv/:id", MediaLive.Show, :show
      live "/music", MusicLive.Index, :index
      live "/music/albums/:id", MusicLive.Show, :show
      live "/music/artists/:id", MusicLive.ArtistShow, :show
      live "/music/playlists", MusicLive.PlaylistIndex, :index
      live "/music/playlists/:id", MusicLive.PlaylistShow, :show
      live "/books", BooksLive.Index, :index
      live "/books/:id", BooksLive.Show, :show
      live "/books/authors/:id", BooksLive.AuthorShow, :show
      live "/adult", AdultLive.Index, :index
      live "/adult/:id", AdultLive.Show, :show
      live "/add/movie", AddMediaLive.Index, :add_movie
      live "/add/series", AddMediaLive.Index, :add_series
      live "/import", ImportMediaLive.Index, :index
      live "/search", SearchLive.Index, :index
      live "/downloads", DownloadsLive.Index, :index
      live "/calendar", CalendarLive.Index, :index
      live "/activity", ActivityLive.Index, :index

      # Collections
      live "/collections", CollectionLive.Index, :index
      live "/collections/:id", CollectionLive.Show, :show

      # Playback routes
      live "/play/:type/:id", PlaybackLive.Show, :show
      get "/covers/:id", CoverController, :show

      # Guest request routes
      live "/request/movie", RequestMediaLive.Index, :request_movie
      live "/request/series", RequestMediaLive.Index, :request_series
      live "/requests", MyRequestsLive.Index, :index
    end
  end

  # Admin redirect routes (before live_session for proper matching)
  scope "/admin", MydiaWeb do
    pipe_through [:browser, :auth, :require_authenticated, :require_admin]

    # Redirect old status routes to consolidated config page
    get "/", RedirectController, :admin_config
    get "/status", RedirectController, :admin_config
  end

  # Admin LiveView routes
  scope "/admin", MydiaWeb do
    pipe_through [:browser, :auth, :require_authenticated, :require_admin]

    live_session :admin,
      on_mount: [
        {MydiaWeb.Live.UserAuth, :ensure_authenticated},
        {MydiaWeb.Live.UserAuth, {:ensure_role, :admin}},
        {MydiaWeb.Live.UserAuth, :load_navigation_data}
      ] do
      live "/config", AdminConfigLive.Index, :index
      live "/import-lists", AdminImportListsLive.Index, :index
      live "/jobs", JobsLive.Index, :index
      live "/requests", AdminRequestsLive.Index, :index
      live "/users", AdminUsersLive.Index, :index
      live "/devices", AdminDevicesLive.Index, :index
    end
  end

  # ErrorTracker dashboard - admin only
  scope "/admin" do
    pipe_through [:browser, :auth, :require_authenticated, :require_admin]
    error_tracker_dashboard("/errors")
  end

  # API routes - authenticated with JWT or API key
  scope "/api/v1", MydiaWeb.Api do
    pipe_through [:api, :api_auth, :require_authenticated]

    # Download clients
    get "/downloads/clients", DownloadClientController, :index
    get "/downloads/clients/:id", DownloadClientController, :show
    post "/downloads/clients/:id/test", DownloadClientController, :test
    post "/downloads/clients/refresh", DownloadClientController, :refresh

    # Indexers
    get "/indexers", IndexerController, :index
    get "/indexers/:id", IndexerController, :show
    post "/indexers/:id/test", IndexerController, :test
    post "/indexers/:id/reset-failures", IndexerController, :reset_failures
    post "/indexers/refresh", IndexerController, :refresh

    # Media items
    get "/media/:id", MediaController, :show
    post "/media/:id/match", MediaController, :match

    # Streaming
    get "/stream/movie/:id", StreamController, :stream_movie
    get "/stream/episode/:id", StreamController, :stream_episode
    get "/stream/file/:id", StreamController, :stream
    get "/stream/:id", StreamController, :stream
    get "/stream/:content_type/:id/candidates", StreamController, :candidates

    # Playback progress
    get "/playback/movie/:id", PlaybackController, :show_movie
    get "/playback/episode/:id", PlaybackController, :show_episode
    get "/playback/file/:id", PlaybackController, :show_file
    post "/playback/movie/:id", PlaybackController, :update_movie
    post "/playback/episode/:id", PlaybackController, :update_episode
    post "/playback/file/:id", PlaybackController, :update_file

    # Thumbnails
    get "/media/:id/thumbnails.vtt", ThumbnailController, :show_vtt
    get "/media/:id/thumbnails.jpg", ThumbnailController, :show_sprite

    # HLS streaming
    post "/hls/start", HlsController, :start_session
    delete "/hls/:session_id", HlsController, :terminate_session
    get "/hls/:session_id/index.m3u8", HlsController, :master_playlist
    get "/hls/:session_id/:track_id/index.m3u8", HlsController, :variant_playlist
    get "/hls/:session_id/:track_id/:segment", HlsController, :segment
    # Support FFmpeg's flat structure (segments in root directory)
    get "/hls/:session_id/:segment", HlsController, :root_segment

    # Media downloads
    get "/download/:content_type/:id/options", DownloadController, :options
    post "/download/:content_type/:id/prepare", DownloadController, :prepare
    get "/download/job/:job_id/status", DownloadController, :job_status
    delete "/download/job/:job_id", DownloadController, :cancel_job
    get "/download/job/:job_id/file", DownloadController, :download_file
  end

  # API routes - admin only
  scope "/api/v1", MydiaWeb.Api do
    pipe_through [:api, :api_auth, :require_authenticated, :require_admin]

    # Configuration management
    get "/config", ConfigController, :index
    get "/config/:key", ConfigController, :show
    put "/config/:key", ConfigController, :update
    delete "/config/:key", ConfigController, :delete
    post "/config/test-connection", ConfigController, :test_connection
  end

  # GraphQL API - authentication handled at resolver level
  # The :api_auth pipeline populates current_user if a valid JWT/API key is provided
  # Individual resolvers check for authentication and return :unauthorized if needed
  scope "/api/graphql" do
    pipe_through [:graphql, :api_auth, :graphql_context]

    forward "/", Absinthe.Plug,
      schema: MydiaWeb.Schema,
      analyze_complexity: true,
      max_complexity: 200
  end

  # GraphiQL interface for development
  if Application.compile_env(:mydia, :dev_routes) do
    scope "/api" do
      pipe_through [:graphql, :api_auth, :graphql_context]

      forward "/graphiql", Absinthe.Plug.GraphiQL,
        schema: MydiaWeb.Schema,
        interface: :playground
    end
  end

  # API v2 routes - authenticated with JWT or API key
  scope "/api/v2", MydiaWeb.Api.V2 do
    pipe_through [:api, :api_auth, :require_authenticated]

    # Browse endpoints
    get "/browse/movies", BrowseController, :list_movies
    get "/browse/movies/:id", BrowseController, :show_movie
    get "/browse/tv", BrowseController, :list_tv_shows
    get "/browse/tv/:id", BrowseController, :show_tv_show
    get "/browse/tv/:id/seasons/:season", BrowseController, :list_season_episodes

    # Discovery endpoints
    get "/discover/continue", DiscoverController, :continue_watching
    get "/discover/recent", DiscoverController, :recent
    get "/discover/up_next", DiscoverController, :up_next

    # Search
    get "/search", SearchController, :index

    # Subtitles
    get "/subtitles/:type/:id", SubtitleController, :index
    get "/subtitles/:type/:id/:track", SubtitleController, :show
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:mydia, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: MydiaWeb.Telemetry
    end
  end
end
