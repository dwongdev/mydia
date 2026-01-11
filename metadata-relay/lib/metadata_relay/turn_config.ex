defmodule MetadataRelay.TurnConfig do
  @moduledoc """
  Generates TURN server credentials for WebRTC clients.

  This module supports three deployment scenarios:

  ## 1. Integrated TURN Server (Recommended)

  When `TURN_ENABLED=true`, metadata-relay runs its own TURN server using the
  processone/stun library. This is the simplest deployment option:

      TURN_ENABLED=true
      TURN_SECRET=<your-secret>
      TURN_PUBLIC_IP=<your-public-ip>  # Required for clients to reach the relay

  The integrated server:
  - Listens on port 3478 (UDP) by default
  - Uses time-limited credentials with HMAC-SHA1 authentication
  - Automatically generates TURN URIs for clients

  ## 2. External Coturn Server

  For production deployments with a dedicated Coturn server:

      TURN_URI=turn:turn.example.com:3478
      TURN_SECRET=<coturn-static-auth-secret>

  Configure Coturn with `use-auth-secret` and the same shared secret.

  ## 3. No TURN Server

  If neither `TURN_ENABLED` nor `TURN_URI` is set, only public STUN servers
  are returned. This works for clients on the same network but may fail
  for NAT traversal scenarios.
  """

  @doc """
  Generates ICE servers configuration.

  Returns a list of ICE server maps suitable for WebRTC configuration.
  Credentials are valid for the specified TTL (default 24 hours).

  ## Options

  * `ttl_seconds` - Time-to-live for credentials in seconds (default: 86,400 = 24h)

  ## Examples

      iex> MetadataRelay.TurnConfig.generate_ice_servers()
      [
        %{
          urls: ["turn:turn.example.com:3478", ...],
          username: "1704153600:mydia-user",
          credential: "abc123..."
        },
        %{urls: "stun:stun.l.google.com:19302"}
      ]
  """
  def generate_ice_servers(ttl_seconds \\ 86_400) do
    turn_uri = get_turn_uri()
    turn_secret = Application.get_env(:metadata_relay, :turn_secret)

    # Always include public STUN servers for initial connectivity checks
    servers = [
      %{urls: "stun:stun.l.google.com:19302"}
    ]

    # Add integrated TURN server's STUN capability if running
    servers = maybe_add_integrated_stun(servers)

    if turn_uri && turn_secret && turn_uri != "" && turn_secret != "" do
      timestamp = System.os_time(:second) + ttl_seconds
      username = "#{timestamp}:mydia-user"

      # HMAC-SHA1 signature (RFC 5389 long-term credential mechanism)
      signature =
        :crypto.mac(:hmac, :sha, turn_secret, username)
        |> Base.encode64()

      # Parse the base URI to create UDP and TCP variants
      # turn_uri is typically "turn:hostname:port"
      base_uri = turn_uri

      # Build URL list - UDP only for integrated server (no TLS support yet)
      urls =
        if integrated_turn_enabled?() do
          # Integrated server: UDP only
          [base_uri]
        else
          # External Coturn: UDP, TCP, and TLS variants
          [
            base_uri,
            "#{base_uri}?transport=tcp",
            String.replace(base_uri, "turn:", "turns:") <> "?transport=tcp"
          ]
        end

      turn_server = %{
        urls: urls,
        username: username,
        credential: signature
      }

      [turn_server | servers]
    else
      servers
    end
  end

  @doc """
  Returns whether the integrated TURN server is enabled.
  """
  def integrated_turn_enabled? do
    Application.get_env(:metadata_relay, :turn_enabled, false)
  end

  @doc """
  Returns the TURN URI (either from integrated server or external config).
  """
  def get_turn_uri do
    Application.get_env(:metadata_relay, :turn_uri)
  end

  # Add the integrated TURN server's address as a STUN server
  # This allows clients to use the same server for both STUN and TURN
  defp maybe_add_integrated_stun(servers) do
    if integrated_turn_enabled?() do
      case MetadataRelay.TurnServer.get_config() do
        %{public_ip: public_ip, port: port, listener_started: true}
        when not is_nil(public_ip) ->
          stun_uri = "stun:#{format_ip(public_ip)}:#{port}"
          [%{urls: stun_uri} | servers]

        _ ->
          servers
      end
    else
      servers
    end
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip) when is_tuple(ip), do: :inet.ntoa(ip) |> to_string()
  defp format_ip(ip) when is_binary(ip), do: ip
  defp format_ip(_), do: nil
end
