defmodule MydiaWeb.Plugs.PlayerProxy do
  @moduledoc """
  Reverse proxy for Flutter player assets in development.

  In development, this plug proxies requests to `/player/*` (except the main
  `/player` route) to the Flutter web dev server running in Docker. This enables:

  - Hot reload/restart for fast development
  - Single URL access via Phoenix (localhost:4000/player)
  - Proper auth injection by PlayerController for the main HTML

  In production, this plug is not used - static files are served from
  `priv/static/player/` via Plug.Static.
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  # Flutter dev server URL (Docker service name)
  @flutter_dev_server "http://player:3000"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: "/player"} = conn, _opts) do
    # Main /player route is handled by PlayerController for auth injection
    conn
  end

  def call(%Plug.Conn{request_path: "/player/" <> asset_path} = conn, _opts) do
    proxy_asset(conn, asset_path)
  end

  def call(conn, _opts), do: conn

  defp proxy_asset(conn, asset_path) do
    url = "#{@flutter_dev_server}/#{asset_path}"

    # Disable automatic JSON decoding to get raw response
    case Req.get(url, receive_timeout: 30_000, decode_body: false) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}}
      when status in 200..299 ->
        content_type = get_content_type(headers, asset_path)
        external_host = get_external_host(conn)

        # Rewrite internal Docker hostname to external host for text content
        # Also rewrite WebSocket paths to go through Phoenix proxy
        rewritten_body =
          if text_content?(content_type) and is_binary(body) do
            body
            |> String.replace("ws://player:3000/", "ws://#{external_host}/player/")
            |> String.replace("http://player:3000/", "http://#{external_host}/player/")
            |> String.replace("player:3000", external_host)
          else
            body
          end

        conn
        |> put_resp_content_type(content_type)
        |> send_resp(status, rewritten_body)
        |> halt()

      {:ok, %Req.Response{status: 404}} ->
        # Asset not found on Flutter server
        conn

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Player proxy got status #{status} for #{asset_path}")

        conn
        |> send_resp(status, body)
        |> halt()

      {:error, reason} ->
        Logger.error("Player proxy failed for #{asset_path}: #{inspect(reason)}")
        # Let it fall through to 404
        conn
    end
  end

  defp get_external_host(conn) do
    get_req_header(conn, "host") |> List.first() || "localhost:4000"
  end

  defp text_content?(content_type) do
    String.starts_with?(content_type, "text/") or
      String.starts_with?(content_type, "application/javascript") or
      String.starts_with?(content_type, "application/json")
  end

  defp get_content_type(headers, asset_path) do
    # Req returns headers as a map of lists, e.g. %{"content-type" => ["text/html"]}
    case Map.get(headers, "content-type") do
      [content_type | _] ->
        content_type

      _ ->
        # Infer from file extension
        infer_content_type(asset_path)
    end
  end

  defp infer_content_type(path) do
    case Path.extname(path) do
      ".js" -> "application/javascript"
      ".mjs" -> "application/javascript"
      ".css" -> "text/css"
      ".html" -> "text/html"
      ".json" -> "application/json"
      ".wasm" -> "application/wasm"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".svg" -> "image/svg+xml"
      ".ico" -> "image/x-icon"
      ".woff" -> "font/woff"
      ".woff2" -> "font/woff2"
      ".ttf" -> "font/ttf"
      ".otf" -> "font/otf"
      _ -> "application/octet-stream"
    end
  end
end
