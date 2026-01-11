defmodule MetadataRelay.TurnConfig do
  @moduledoc """
  Generates TURN server credentials for clients.
  """

  @doc """
  Generates ICE servers configuration.
  
  Returns a list of ICE server maps suitable for WebRTC configuration.
  Credentials are valid for the specified TTL (default 24 hours).
  """
  def generate_ice_servers(ttl_seconds \\ 86_400) do
    turn_uri = Application.get_env(:metadata_relay, :turn_uri)
    turn_secret = Application.get_env(:metadata_relay, :turn_secret)

    servers = [
      %{urls: "stun:stun.l.google.com:19302"}
    ]

    if turn_uri && turn_secret && turn_uri != "" && turn_secret != "" do
      timestamp = System.os_time(:second) + ttl_seconds
      username = "#{timestamp}:mydia-user"
      
      # HMAC-SHA1 signature
      signature = 
        :crypto.mac(:hmac, :sha, turn_secret, username)
        |> Base.encode64()

      # Parse the base URI to create UDP and TCP variants
      # turn_uri is typically "turn:hostname:port"
      base_uri = turn_uri
      
      # Add both UDP and TCP/TLS variants for better connectivity
      turn_server = %{
        urls: [
          base_uri,                           # UDP (default)
          "#{base_uri}?transport=tcp",        # TCP fallback
          String.replace(base_uri, "turn:", "turns:") <> "?transport=tcp"  # TLS fallback
        ],
        username: username,
        credential: signature
      }
      
      [turn_server | servers]
    else
      servers
    end
  end
end
