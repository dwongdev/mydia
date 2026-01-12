defmodule MetadataRelay.P2p.Server do
  use GenServer
  require Logger

  alias MetadataRelay.P2p

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    # Start the relay host
    case P2p.start_relay() do
      {:ok, {resource, peer_id}} ->
        Logger.info("Libp2p Relay Server started with PeerID: #{peer_id}")

        # Listen on all interfaces, TCP port 4001 (standard for libp2p)
        # We might want to make this configurable via env vars
        case P2p.listen(resource, "/ip4/0.0.0.0/tcp/4001") do
          {:ok, "ok"} ->
            Logger.info("Libp2p Relay listening on /ip4/0.0.0.0/tcp/4001")
            {:ok, %{resource: resource, peer_id: peer_id}}

          error ->
            {:stop, error}
        end

      error ->
        {:stop, error}
    end
  end
end
