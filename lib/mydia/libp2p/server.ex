defmodule Mydia.Libp2p.Server do
  use GenServer
  require Logger

  alias Mydia.Libp2p
  alias Mydia.RemoteAccess.Pairing

  @doc """
  Status information about the libp2p host.
  """
  defmodule Status do
    defstruct [
      :peer_id,
      :running,
      :dht_bootstrapped,
      :connected_peers,
      :discovered_peers,
      :relay_connected,
      :relayed_address,
      :rendezvous_connected,
      :active_registrations
    ]

    @type t :: %__MODULE__{
            peer_id: String.t() | nil,
            running: boolean(),
            dht_bootstrapped: boolean(),
            connected_peers: non_neg_integer(),
            discovered_peers: non_neg_integer(),
            relay_connected: boolean(),
            relayed_address: String.t() | nil,
            rendezvous_connected: boolean(),
            active_registrations: non_neg_integer()
          }
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    # Start the host - NIF returns {resource, peer_id} directly (raises on error)
    {resource, peer_id} = Libp2p.start_host()
    Logger.info("Libp2p Host started with PeerID: #{peer_id}")

    # Start listening for events, sending them to self()
    # NIF returns "ok" directly (raises on error)
    "ok" = Libp2p.start_listening(resource, self())

    # Note: We don't listen on a TCP port by default since the container
    # typically only exposes port 4000 for HTTP. Libp2p works in outbound-only
    # mode - we can still bootstrap DHT and make requests to other peers.
    # For incoming p2p connections, clients connect via the relay or mDNS.

    state = %{
      resource: resource,
      peer_id: peer_id,
      dht_bootstrapped: false,
      relay_connected: false,
      relayed_address: nil,
      rendezvous_connected: false,
      # Track discovered peers via mDNS (MapSet of peer IDs)
      discovered_peers: MapSet.new(),
      # Track connected peers (MapSet of peer IDs)
      connected_peers: MapSet.new(),
      # Track namespaces we're registered under: %{namespace => :pending | :registered | {:error, reason}}
      registered_namespaces: %{},
      # Track refresh timers for namespaces
      namespace_refresh_timers: %{}
    }

    # Schedule relay connection after init completes
    # This allows the GenServer to start up quickly
    send(self(), :connect_to_relay)

    {:ok, state}
  end

  def listen(addr) do
    GenServer.call(__MODULE__, {:listen, addr})
  end

  def dial(addr) do
    GenServer.call(__MODULE__, {:dial, addr})
  end

  @doc """
  Add a bootstrap peer and initiate DHT bootstrap.
  The address should include the peer ID, e.g., "/ip4/1.2.3.4/tcp/4001/p2p/12D3..."
  """
  def bootstrap(addr) do
    GenServer.call(__MODULE__, {:bootstrap, addr})
  end

  @doc """
  Connect to a relay server and request a reservation.
  This allows clients to connect to us through the relay for NAT traversal.
  """
  def connect_relay(relay_addr) do
    GenServer.call(__MODULE__, {:connect_relay, relay_addr})
  end

  @doc """
  Fetch relay info from the default relay server and connect to it.
  Uses the RELAY_URL environment variable or defaults to https://p2p.mydia.dev
  """
  def connect_to_default_relay do
    GenServer.call(__MODULE__, :connect_to_default_relay, 30_000)
  end

  @doc """
  Register under a namespace with the rendezvous point.
  This is used during pairing mode to make the server discoverable.

  ## Parameters
  - namespace: The rendezvous namespace (e.g., "mydia-claim:BASE32TOKEN")
  - ttl_secs: Time-to-live in seconds (registration will be refreshed automatically)
  """
  def register_namespace(namespace, ttl_secs \\ 120) do
    GenServer.call(__MODULE__, {:register_namespace, namespace, ttl_secs}, 30_000)
  end

  @doc """
  Unregister from a namespace.
  """
  def unregister_namespace(namespace) do
    GenServer.call(__MODULE__, {:unregister_namespace, namespace})
  end

  @doc """
  Get the registration status of a namespace.
  Returns :not_found, :pending, :registered, or {:error, reason}.
  """
  @spec namespace_status(String.t()) :: :not_found | :pending | :registered | {:error, term()}
  def namespace_status(namespace) do
    GenServer.call(__MODULE__, {:namespace_status, namespace})
  end

  @doc """
  Get the peer ID of the libp2p host.
  """
  def peer_id do
    GenServer.call(__MODULE__, :peer_id)
  end

  @doc """
  Get the current status of the libp2p host.
  """
  @spec status() :: Status.t()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Get network statistics from the libp2p host.
  """
  @spec network_stats() :: Libp2p.NetworkStats.t()
  def network_stats do
    GenServer.call(__MODULE__, :network_stats)
  end

  def handle_call({:listen, addr}, _from, state) do
    result = Libp2p.listen(state.resource, addr)
    {:reply, result, state}
  end

  def handle_call({:dial, addr}, _from, state) do
    result = Libp2p.dial(state.resource, addr)
    {:reply, result, state}
  end

  def handle_call({:bootstrap, addr}, _from, state) do
    result = Libp2p.bootstrap(state.resource, addr)
    {:reply, result, state}
  end

  def handle_call({:register_namespace, namespace, ttl_secs}, _from, state) do
    # Mark as pending while we try to register
    state = put_in(state, [:registered_namespaces, namespace], :pending)

    result =
      case Libp2p.register_namespace(state.resource, namespace, ttl_secs) do
        "ok" -> {:ok, :registered}
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end

    # Update status based on result
    state =
      case result do
        {:ok, _} ->
          state = put_in(state, [:registered_namespaces, namespace], :registered)
          # Schedule refresh at ~60% of TTL with jitter
          refresh_ms = trunc(ttl_secs * 600 + :rand.uniform(ttl_secs * 200))

          timer_ref =
            Process.send_after(self(), {:refresh_namespace, namespace, ttl_secs}, refresh_ms)

          put_in(state, [:namespace_refresh_timers, namespace], timer_ref)

        {:error, reason} ->
          put_in(state, [:registered_namespaces, namespace], {:error, reason})
      end

    {:reply, result, state}
  end

  def handle_call({:unregister_namespace, namespace}, _from, state) do
    # Cancel refresh timer if exists
    state =
      case Map.get(state.namespace_refresh_timers, namespace) do
        nil ->
          state

        timer_ref ->
          Process.cancel_timer(timer_ref)
          update_in(state, [:namespace_refresh_timers], &Map.delete(&1, namespace))
      end

    result = Libp2p.unregister_namespace(state.resource, namespace)
    state = update_in(state, [:registered_namespaces], &Map.delete(&1, namespace))

    {:reply, result, state}
  end

  def handle_call({:namespace_status, namespace}, _from, state) do
    status = Map.get(state.registered_namespaces, namespace, :not_found)
    {:reply, status, state}
  end

  def handle_call(:peer_id, _from, state) do
    {:reply, state.peer_id, state}
  end

  def handle_call(:status, _from, state) do
    status = %Status{
      peer_id: state.peer_id,
      running: true,
      dht_bootstrapped: state.dht_bootstrapped,
      connected_peers: MapSet.size(state.connected_peers),
      discovered_peers: MapSet.size(state.discovered_peers),
      relay_connected: state.relay_connected,
      relayed_address: state.relayed_address,
      rendezvous_connected: state.rendezvous_connected,
      active_registrations: map_size(state.registered_namespaces)
    }

    {:reply, status, state}
  end

  def handle_call(:network_stats, _from, state) do
    stats = Libp2p.get_network_stats(state.resource)
    {:reply, stats, state}
  end

  def handle_call({:connect_relay, relay_addr}, _from, state) do
    result = Libp2p.connect_relay(state.resource, relay_addr)
    {:reply, result, state}
  end

  def handle_call(:connect_to_default_relay, _from, state) do
    result = do_connect_to_default_relay(state)
    {:reply, result, state}
  end

  # Handle namespace refresh
  def handle_info({:refresh_namespace, namespace, ttl_secs}, state) do
    case Map.get(state.registered_namespaces, namespace) do
      :registered ->
        Logger.debug("Refreshing namespace registration: #{namespace}")

        case Libp2p.register_namespace(state.resource, namespace, ttl_secs) do
          "ok" ->
            # Schedule next refresh
            refresh_ms = trunc(ttl_secs * 600 + :rand.uniform(ttl_secs * 200))

            timer_ref =
              Process.send_after(self(), {:refresh_namespace, namespace, ttl_secs}, refresh_ms)

            state = put_in(state, [:namespace_refresh_timers, namespace], timer_ref)
            {:noreply, state}

          {:error, reason} ->
            Logger.warning("Failed to refresh namespace #{namespace}: #{inspect(reason)}")
            # Retry with exponential backoff (start at 1 second, max 16 seconds)
            retry_ms = min(1000 * :math.pow(2, :rand.uniform(4)), 16_000)

            timer_ref =
              Process.send_after(
                self(),
                {:refresh_namespace, namespace, ttl_secs},
                trunc(retry_ms)
              )

            state = put_in(state, [:namespace_refresh_timers, namespace], timer_ref)
            {:noreply, state}

          other ->
            Logger.warning("Unexpected refresh result for #{namespace}: #{inspect(other)}")
            {:noreply, state}
        end

      _ ->
        # Namespace no longer registered, don't refresh
        {:noreply, state}
    end
  end

  # Handle events from Rust
  def handle_info({:ok, "peer_discovered", peer_id}, state) do
    Logger.info("Libp2p Event: Peer Discovered #{peer_id}")
    state = %{state | discovered_peers: MapSet.put(state.discovered_peers, peer_id)}
    {:noreply, state}
  end

  def handle_info({:ok, "peer_expired", peer_id}, state) do
    Logger.info("Libp2p Event: Peer Expired #{peer_id}")
    state = %{state | discovered_peers: MapSet.delete(state.discovered_peers, peer_id)}
    {:noreply, state}
  end

  def handle_info({:ok, "peer_connected", peer_id}, state) do
    Logger.info("Libp2p Event: Peer Connected #{peer_id}")
    state = %{state | connected_peers: MapSet.put(state.connected_peers, peer_id)}
    {:noreply, state}
  end

  def handle_info({:ok, "peer_disconnected", peer_id}, state) do
    Logger.info("Libp2p Event: Peer Disconnected #{peer_id}")
    state = %{state | connected_peers: MapSet.delete(state.connected_peers, peer_id)}
    {:noreply, state}
  end

  def handle_info({:ok, "bootstrap_completed"}, state) do
    Logger.info("Libp2p Event: DHT Bootstrap Completed")
    state = %{state | dht_bootstrapped: true}
    {:noreply, state}
  end

  def handle_info({:ok, "new_listen_addr", addr}, state) do
    Logger.info("Libp2p Event: New listen address: #{addr}")
    {:noreply, state}
  end

  def handle_info({:ok, "relay_ready", relay_peer_id, relayed_addr}, state) do
    Logger.info("Libp2p Event: Relay reservation ready via #{relay_peer_id}")
    Logger.info("Libp2p Event: Relayed address: #{relayed_addr}")
    state = %{state | relay_connected: true, relayed_address: relayed_addr}
    {:noreply, state}
  end

  def handle_info({:ok, "relay_failed", relay_peer_id, error}, state) do
    Logger.warning("Libp2p Event: Relay reservation failed for #{relay_peer_id}: #{error}")
    {:noreply, state}
  end

  def handle_info({:ok, "rendezvous_registered", namespace}, state) do
    Logger.info("Libp2p Event: Registered in namespace #{namespace}")
    state = %{state | rendezvous_connected: true}
    state = put_in(state, [:registered_namespaces, namespace], :registered)
    {:noreply, state}
  end

  def handle_info({:ok, "rendezvous_registration_failed", namespace, error}, state) do
    Logger.warning("Libp2p Event: Failed to register in namespace #{namespace}: #{error}")
    state = put_in(state, [:registered_namespaces, namespace], {:error, error})
    {:noreply, state}
  end

  def handle_info({:ok, "rendezvous_discovered", namespace, peers}, state) do
    Logger.info("Libp2p Event: Discovered #{length(peers)} peers in namespace #{namespace}")
    {:noreply, state}
  end

  def handle_info(:connect_to_relay, state) do
    # Auto-connect to default relay on startup
    case do_connect_to_default_relay(state) do
      {:ok, _} ->
        Logger.info("Connected to relay server")

      {:error, reason} ->
        Logger.warning("Failed to connect to relay server: #{inspect(reason)}")
        # Retry after 30 seconds
        Process.send_after(self(), :connect_to_relay, 30_000)
    end

    {:noreply, state}
  end

  def handle_info({:ok, "request_received", "pairing", request_id, req}, state) do
    Logger.info("Libp2p Request: Pairing from #{req.device_name}")

    device_attrs = %{
      name: req.device_name,
      # mapping type to client_name
      client_name: req.device_type,
      # TODO: Add version to request
      client_version: "1.0.0",
      device_os: req.device_os || "unknown"
    }

    response =
      case Pairing.complete_pairing(req.claim_code, device_attrs) do
        {:ok, _device, media_token, access_token, device_token} ->
          %Libp2p.PairingResponse{
            success: true,
            media_token: media_token,
            access_token: access_token,
            device_token: device_token,
            error: nil
          }

        {:error, reason} ->
          Logger.warning("Pairing failed: #{inspect(reason)}")

          %Libp2p.PairingResponse{
            success: false,
            error: inspect(reason)
          }
      end

    # Wrap in tagged enum tuple as expected by NIF
    response_enum = {:pairing, response}

    Libp2p.send_response(state.resource, request_id, response_enum)
    {:noreply, state}
  end

  def handle_info({:ok, "request_received", "ping", _request_id}, state) do
    Logger.debug("Libp2p Ping Request received (manual)")
    {:noreply, state}
  end

  def handle_info({:ok, "request_received", "read_media", request_id, req}, state) do
    # Validate file path exists
    # SECURITY: In production, verify path is within allowed directories!
    if File.exists?(req.file_path) do
      # Use the optimized NIF to read chunk and respond
      Libp2p.respond_with_file_chunk(
        state.resource,
        request_id,
        req.file_path,
        req.offset,
        req.length
      )
    else
      Logger.warning("Requested file not found: #{req.file_path}")
      Libp2p.send_response(state.resource, request_id, {:error, "File not found"})
    end

    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("Libp2p Unhandled Event: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private helpers

  @default_relay_url "https://relay.mydia.dev"

  defp do_connect_to_default_relay(state) do
    relay_url = System.get_env("RELAY_URL", @default_relay_url)

    with {:ok, relay_info} <- fetch_relay_info(relay_url),
         multiaddr when is_binary(multiaddr) <- get_best_multiaddr(relay_info) do
      Logger.info("DEBUG: relay_info multiaddrs: #{inspect(relay_info["multiaddrs"])}")
      Logger.info("Connecting to relay: #{multiaddr}")

      case Libp2p.connect_relay(state.resource, multiaddr) do
        "ok" -> {:ok, multiaddr}
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :no_relay_addresses}
    end
  end

  defp fetch_relay_info(relay_url) do
    # Add cache-busting parameter to avoid stale cached peer IDs
    url = "#{relay_url}/p2p/info?_cb=#{System.system_time(:millisecond)}"
    Logger.debug("Fetching relay info from #{url}")

    case Req.get(url, headers: [{"cache-control", "no-cache"}]) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Failed to fetch relay info: HTTP #{status} - #{inspect(body)}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("Failed to fetch relay info: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_best_multiaddr(relay_info) when is_map(relay_info) do
    multiaddrs = relay_info["multiaddrs"] || []

    # Prefer IP-based addresses over DNS-based (more reliable)
    # STRIP the Peer ID from the address so we don't enforce a stale one from the relay info.
    # We will trust the IP address and accept whatever Peer ID the server presents during handshake.
    ip_addr =
      Enum.find_value(multiaddrs, fn addr ->
        if String.starts_with?(addr, "/ip4/") do
          strip_peer_id(addr)
        else
          nil
        end
      end)

    if ip_addr do
      ip_addr
    else
      # Fall back to DNS-based
      # Don't manually resolve, let Rust libp2p handle it (it has DNS transport)
      if addr = relay_info["primary_multiaddr"] || List.first(multiaddrs) do
        strip_peer_id(addr)
      end
    end
  end

  defp get_best_multiaddr(_), do: nil

  defp strip_peer_id(addr) do
    # Remove /p2p/XXXX suffix if present
    String.replace(addr, ~r{/p2p/[^/]+$}, "")
  end
end
