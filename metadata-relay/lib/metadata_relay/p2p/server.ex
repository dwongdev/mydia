defmodule MetadataRelay.P2p.Server do
  @moduledoc """
  GenServer that manages the iroh P2P host.

  Note: With the migration to iroh, the metadata-relay no longer needs to run
  its own relay server. iroh uses its own public relay infrastructure.
  This server is kept for backwards compatibility but doesn't provide
  relay functionality - it's just a regular iroh endpoint.

  Clients can query this via the /p2p/info endpoint for the node address.
  """
  use GenServer
  require Logger

  alias MetadataRelay.P2p

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Get the P2P server info including node ID and addresses.
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
    case P2p.start_relay() do
      {:ok, {resource, node_id}} ->
        Logger.info("P2P host started with NodeID: #{node_id}")
        {:ok, %{resource: resource, node_id: node_id}}

      {resource, node_id} when is_reference(resource) and is_binary(node_id) ->
        Logger.info("P2P host started with NodeID: #{node_id}")
        {:ok, %{resource: resource, node_id: node_id}}

      {:error, reason} ->
        Logger.error("Failed to start P2P host: #{inspect(reason)}")
        {:stop, {:error, reason}}

      error ->
        Logger.error("Failed to start P2P host: #{inspect(error)}")
        {:stop, error}
    end
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = build_info(state)
    {:reply, {:ok, info}, state}
  end

  defp build_info(state) do
    node_id = state.node_id

    # Get node address as JSON (returns String directly)
    node_addr = P2p.get_node_addr(state.resource)

    # Treat empty JSON as nil
    node_addr = if node_addr == "{}", do: nil, else: node_addr

    %{
      node_id: node_id,
      node_addr: node_addr,
      # Legacy fields for backwards compatibility
      peer_id: node_id,
      addresses: if(node_addr, do: [node_addr], else: []),
      multiaddrs: [],
      primary_multiaddr: nil,
      protocol_version: "mydia/iroh/1.0.0"
    }
  end
end
