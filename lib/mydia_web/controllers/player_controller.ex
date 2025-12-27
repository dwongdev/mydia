defmodule MydiaWeb.PlayerController do
  use MydiaWeb, :controller

  alias Mydia.Auth.Guardian

  @moduledoc """
  Serves the Flutter web player application.

  This controller handles all /player/* routes and serves the Flutter
  web app's index.html, allowing Flutter's hash-based routing to work.

  For authenticated users, the controller injects auth configuration
  into the HTML so the Flutter app can auto-authenticate without
  requiring manual login.
  """

  @doc """
  Serves the Flutter web player's index.html for all /player/* routes.

  The Flutter app uses hash-based routing (e.g., /player/#/movies/123),
  so all routes should serve the same index.html and let Flutter handle
  the routing on the client side.

  For authenticated users, injects:
  - Auth token (JWT)
  - User info (id, username)
  - Server URL is auto-detected by Flutter from window.location.origin
  """
  def index(conn, _params) do
    player_index_path = Path.join([:code.priv_dir(:mydia), "static", "player", "index.html"])

    if File.exists?(player_index_path) do
      # Read the original Flutter index.html
      html_content = File.read!(player_index_path)

      # Get auth info from session
      auth_config = build_auth_config(conn)

      # Inject auth config before the Flutter bootstrap
      modified_html = inject_auth_config(html_content, auth_config)

      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, modified_html)
    else
      conn
      |> put_status(:not_found)
      |> put_view(html: MydiaWeb.ErrorHTML)
      |> render(:"404")
    end
  end

  # Build the auth configuration to inject into the page
  defp build_auth_config(conn) do
    case Guardian.Plug.current_resource(conn) do
      nil ->
        # No authenticated user
        %{authenticated: false, embedMode: true}

      user ->
        # Get the token from session (check both Guardian default key and legacy key)
        token =
          get_session(conn, :guardian_default_token) ||
            get_session(conn, :guardian_token) ||
            create_fresh_token(user)

        %{
          authenticated: true,
          token: token,
          userId: user.id,
          username: user.username,
          embedMode: true
        }
    end
  end

  # Create a fresh token if one doesn't exist in the session
  defp create_fresh_token(user) do
    case Guardian.create_token(user) do
      {:ok, token, _claims} -> token
      _ -> nil
    end
  end

  # Inject auth config as a JavaScript global before the Flutter bootstrap
  defp inject_auth_config(html_content, auth_config) do
    config_json = Jason.encode!(auth_config)

    auth_script = """
    <script>
      // Mydia auth configuration injected by Phoenix
      // Flutter web app reads this to auto-authenticate
      window.mydiaConfig = #{config_json};
    </script>
    """

    # Insert the auth script just before the flutter_bootstrap.js script
    String.replace(
      html_content,
      ~r/<script src="flutter_bootstrap\.js"/,
      auth_script <> "\n  <script src=\"flutter_bootstrap.js\""
    )
  end
end
