defmodule Mydia.Libp2p.Server do
  use GenServer
  require Logger

  alias Mydia.Libp2p
  alias Mydia.RemoteAccess.Pairing

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    # Start the host
    case Libp2p.start_host() do
      {:ok, {resource, peer_id}} ->
        Logger.info("Libp2p Host started with PeerID: #{peer_id}")

        # Start listening for events, sending them to self()
        case Libp2p.start_listening(resource, self()) do
          {:ok, "ok"} ->
            {:ok, %{resource: resource, peer_id: peer_id}}

          error ->
            {:stop, error}
        end

      error ->
        {:stop, error}
    end
  end

  def listen(addr) do
    GenServer.call(__MODULE__, {:listen, addr})
  end

  def dial(addr) do
    GenServer.call(__MODULE__, {:dial, addr})
  end

  def handle_call({:listen, addr}, _from, state) do
    result = Libp2p.listen(state.resource, addr)
    {:reply, result, state}
  end

  def handle_call({:dial, addr}, _from, state) do
    result = Libp2p.dial(state.resource, addr)
    {:reply, result, state}
  end

  # Handle events from Rust
  def handle_info({:ok, "peer_discovered", peer_id}, state) do
    Logger.info("Libp2p Event: Peer Discovered #{peer_id}")
    {:noreply, state}
  end

  def handle_info({:ok, "peer_expired", peer_id}, state) do
    Logger.info("Libp2p Event: Peer Expired #{peer_id}")
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

  def handle_info({:ok, "request_received", "ping", request_id}, state) do
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
