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
      :discovered_peers
    ]

    @type t :: %__MODULE__{
            peer_id: String.t() | nil,
            running: boolean(),
            dht_bootstrapped: boolean(),
            connected_peers: non_neg_integer(),
            discovered_peers: non_neg_integer()
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

    {:ok,
     %{
       resource: resource,
       peer_id: peer_id,
       dht_bootstrapped: false,
       # Track discovered peers via mDNS (MapSet of peer IDs)
       discovered_peers: MapSet.new(),
       # Track connected peers (MapSet of peer IDs)
       connected_peers: MapSet.new(),
       # Track claim codes we're providing on DHT: %{code => :pending | :registered | {:error, reason}}
       provided_claim_codes: %{}
     }}
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
  Provide a claim code on the DHT, announcing this server as the provider.
  """
  def provide_claim_code(claim_code) do
    GenServer.call(__MODULE__, {:provide_claim_code, claim_code}, 30_000)
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
  Get DHT statistics from the libp2p host.
  """
  @spec dht_stats() :: Libp2p.DhtStats.t()
  def dht_stats do
    GenServer.call(__MODULE__, :dht_stats)
  end

  @doc """
  Get the registration status of a claim code on the DHT.
  Returns :not_found, :pending, :registered, or {:error, reason}.
  """
  @spec claim_code_status(String.t()) :: :not_found | :pending | :registered | {:error, term()}
  def claim_code_status(claim_code) do
    GenServer.call(__MODULE__, {:claim_code_status, claim_code})
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

  def handle_call({:provide_claim_code, claim_code}, _from, state) do
    # Mark as pending while we try to register
    state = put_in(state, [:provided_claim_codes, claim_code], :pending)

    result =
      case Libp2p.provide_claim_code(state.resource, claim_code) do
        "ok" -> {:ok, :provided}
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end

    # Update status based on result
    state =
      case result do
        {:ok, _} ->
          put_in(state, [:provided_claim_codes, claim_code], :registered)

        {:error, reason} ->
          put_in(state, [:provided_claim_codes, claim_code], {:error, reason})
      end

    {:reply, result, state}
  end

  def handle_call(:peer_id, _from, state) do
    {:reply, state.peer_id, state}
  end

  def handle_call({:claim_code_status, claim_code}, _from, state) do
    status = Map.get(state.provided_claim_codes, claim_code, :not_found)
    {:reply, status, state}
  end

  def handle_call(:status, _from, state) do
    status = %Status{
      peer_id: state.peer_id,
      running: true,
      dht_bootstrapped: state.dht_bootstrapped,
      connected_peers: MapSet.size(state.connected_peers),
      discovered_peers: MapSet.size(state.discovered_peers)
    }

    {:reply, status, state}
  end

  def handle_call(:dht_stats, _from, state) do
    stats = Libp2p.get_dht_stats(state.resource)
    {:reply, stats, state}
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
end
