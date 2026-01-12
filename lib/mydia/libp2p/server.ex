defmodule Mydia.Libp2p.Server do
  use GenServer
  require Logger

  alias Mydia.Libp2p

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
    # TODO: Broadcast to PubSub
    {:noreply, state}
  end

  def handle_info({:ok, "peer_expired", peer_id}, state) do
    Logger.info("Libp2p Event: Peer Expired #{peer_id}")
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("Libp2p Unhandled Event: #{inspect(msg)}")
    {:noreply, state}
  end
end
