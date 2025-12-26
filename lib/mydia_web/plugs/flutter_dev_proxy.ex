defmodule MydiaWeb.Plugs.FlutterDevProxy do
  @moduledoc """
  Proxies /player/* requests to the Flutter dev server during development.

  This plug only activates in development mode when the Flutter dev server
  is running on localhost:3000. In production, the static files are served
  from priv/static/player instead.

  For index.html requests, injects auth configuration so the Flutter app
  can auto-authenticate (same as PlayerController does in production).
  """

  @behaviour Plug

  import Plug.Conn

  alias Mydia.Auth.Guardian

  def init(opts), do: opts

  def call(conn, _opts) do
    if development_mode?() and flutter_path?(conn.request_path) do
      # Fetch session so we can read auth token for injection
      conn
      |> fetch_session()
      |> proxy_to_flutter()
    else
      conn
    end
  end

  defp development_mode? do
    Application.get_env(:mydia, :dev_routes, false)
  end

  defp flutter_path?(path) do
    String.starts_with?(path, "/player")
  end

  defp proxy_to_flutter(conn) do
    # In Docker Compose, use the service name; outside Docker, use localhost
    flutter_dev_url = System.get_env("FLUTTER_DEV_URL", "http://flutter:3000")

    # Build the target URL
    target_path = String.replace_prefix(conn.request_path, "/player", "")
    target_path = if target_path == "", do: "/", else: target_path
    target_url = flutter_dev_url <> target_path

    # Add query string if present
    target_url =
      if conn.query_string != "" do
        target_url <> "?" <> conn.query_string
      else
        target_url
      end

    case Req.get(target_url, redirect: false) do
      {:ok, response} ->
        # Check if this is an HTML response (index.html) that needs auth injection
        body =
          if is_html_response?(response) do
            inject_auth_config(conn, response.body)
          else
            response.body
          end

        conn
        |> put_proxy_headers(response.headers)
        |> send_resp(response.status, body)
        |> halt()

      {:error, _reason} ->
        # Flutter dev server not running, let the request continue
        # to be handled by the PlayerController or static file serving
        conn
    end
  end

  defp is_html_response?(response) do
    case Map.get(response.headers, "content-type") do
      [content_type | _] -> String.contains?(content_type, "text/html")
      content_type when is_binary(content_type) -> String.contains?(content_type, "text/html")
      _ -> false
    end
  end

  # Inject auth config into HTML response (mirrors PlayerController logic)
  defp inject_auth_config(conn, html_content) when is_binary(html_content) do
    auth_config = build_auth_config(conn)
    config_json = Jason.encode!(auth_config)

    auth_script = """
    <script>
      // Mydia auth configuration injected by Phoenix (dev mode)
      // Flutter web app reads this to auto-authenticate
      window.mydiaConfig = #{config_json};
    </script>
    """

    html_content
    # Fix base href so assets load from /player/ path
    |> String.replace(~r/<base href="[^"]*">/, ~s(<base href="/player/">))
    # Insert the auth script just before the closing </head> tag
    |> String.replace("</head>", auth_script <> "\n</head>", global: false)
  end

  defp inject_auth_config(_conn, body), do: body

  defp build_auth_config(conn) do
    # Get token from session (we're before the router, so Guardian hasn't run yet)
    token =
      get_session(conn, :guardian_default_token) ||
        get_session(conn, :guardian_token)

    case token do
      nil ->
        %{authenticated: false}

      token ->
        # Verify the token to get the user
        case Guardian.verify_token(token) do
          {:ok, user} ->
            %{
              authenticated: true,
              token: token,
              userId: user.id,
              username: user.username
            }

          {:error, _reason} ->
            %{authenticated: false}
        end
    end
  end

  defp put_proxy_headers(conn, headers) do
    # Forward relevant headers from the Flutter dev server
    # Req returns headers as a map with list values
    headers_to_forward = ["content-type", "cache-control", "etag", "last-modified"]

    Enum.reduce(headers_to_forward, conn, fn header_name, acc ->
      case Map.get(headers, header_name) do
        [value | _] ->
          put_resp_header(acc, header_name, value)

        value when is_binary(value) ->
          put_resp_header(acc, header_name, value)

        _ ->
          acc
      end
    end)
  end
end
