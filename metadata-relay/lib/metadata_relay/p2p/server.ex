defmodule MetadataRelay.P2p.Server do
  @moduledoc """
  GenServer that manages the libp2p relay host.

  Provides relay functionality for NAT traversal and peer discovery.
  Clients can discover this relay via the /p2p/info endpoint.
  """
  use GenServer
  require Logger

  alias MetadataRelay.P2p

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Get the relay server info including peer ID and multiaddrs.
  Returns {:ok, info} or {:error, :not_running}
  """
  def get_info do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :get_info)
    else
      {:error, :not_running}
    end
  end

  @impl true
  def init(_) do
    # Start the relay host
    # Handle both {:ok, {resource, peer_id}} and {resource, peer_id} return formats
    case P2p.start_relay() do
      {:ok, {resource, peer_id}} ->
        start_listening(resource, peer_id)

      {resource, peer_id} when is_reference(resource) and is_binary(peer_id) ->
        start_listening(resource, peer_id)

      {:error, reason} ->
        {:stop, {:error, reason}}

      error ->
        {:stop, error}
    end
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = build_info(state)
    {:reply, {:ok, info}, state}
  end

  defp start_listening(resource, peer_id) do
    Logger.info("Libp2p Relay Server started with PeerID: #{peer_id}")

    # Listen on all interfaces, TCP port from env or default 4001
    port = System.get_env("LIBP2P_PORT", "4001")
    listen_addr = "/ip4/0.0.0.0/tcp/#{port}"

    case P2p.listen(resource, listen_addr) do
      {:ok, "ok"} ->
        Logger.info("Libp2p Relay listening on #{listen_addr}")
        add_external_addresses(resource, port)
        {:ok, %{resource: resource, peer_id: peer_id, port: port}}

      "ok" ->
        Logger.info("Libp2p Relay listening on #{listen_addr}")
        add_external_addresses(resource, port)
        {:ok, %{resource: resource, peer_id: peer_id, port: port}}

      {:error, reason} ->
        {:stop, {:error, reason}}

      error ->
        {:stop, error}
    end
  end

  # Add external addresses so the relay server can include them in relay reservations
  defp add_external_addresses(resource, port) do
    # Add DNS-based address if configured
    case System.get_env("LIBP2P_EXTERNAL_HOST") do
      nil ->
        :ok

      "" ->
        :ok

      host ->
        addr = "/dns4/#{host}/tcp/#{port}"
        Logger.info("Adding external address: #{addr}")
        P2p.add_external_address(resource, addr)
    end

    # Add IP-based address if configured
    case System.get_env("LIBP2P_EXTERNAL_IP") do
      nil ->
        :ok

      "" ->
        :ok

      ip ->
        addr = "/ip4/#{ip}/tcp/#{port}"
        Logger.info("Adding external address: #{addr}")
        P2p.add_external_address(resource, addr)
    end
  end

  defp build_info(state) do
    peer_id = state.peer_id
    port = state.port

    # Build multiaddrs for clients to connect
    # Priority: DNS hostname > public IP
    multiaddrs = build_multiaddrs(peer_id, port)

    %{
      peer_id: peer_id,
      multiaddrs: multiaddrs,
      # Primary multiaddr for easy copy/paste
      primary_multiaddr: List.first(multiaddrs),
      protocol_version: "mydia/1.0.0"
    }
  end

  defp build_multiaddrs(peer_id, port) do
    addrs = []

    # Add DNS-based multiaddr if LIBP2P_EXTERNAL_HOST is set
    addrs =
      case System.get_env("LIBP2P_EXTERNAL_HOST") do
        nil -> addrs
        "" -> addrs
        host -> ["/dns4/#{host}/tcp/#{port}/p2p/#{peer_id}" | addrs]
      end

    # Add IP-based multiaddr if LIBP2P_EXTERNAL_IP is set
    addrs =
      case System.get_env("LIBP2P_EXTERNAL_IP") do
        nil -> addrs
        "" -> addrs
        ip -> ["/ip4/#{ip}/tcp/#{port}/p2p/#{peer_id}" | addrs]
      end

    # If no external addresses configured, try to get from PHX_HOST
    # (fallback, though this goes through Cloudflare which won't work for port 4001)
    addrs =
      if addrs == [] do
        case System.get_env("PHX_HOST") do
          nil -> addrs
          "" -> addrs
          # Don't add PHX_HOST as it goes through Cloudflare proxy
          _host -> addrs
        end
      else
        addrs
      end

    Enum.reverse(addrs)
  end
end
