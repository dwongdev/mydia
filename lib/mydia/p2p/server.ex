defmodule Mydia.P2p.Server do
  @moduledoc """
  GenServer that manages the iroh-based p2p host.

  This server wraps the Rust NIF and handles p2p events, forwarding
  pairing requests to the appropriate handlers.
  """
  use GenServer
  require Logger

  alias Mydia.P2p
  alias Mydia.RemoteAccess.Pairing

  @doc """
  Status information about the p2p host.
  """
  defmodule Status do
    defstruct [
      :node_id,
      :node_addr,
      :running,
      :connected_peers,
      :relay_connected
    ]

    @type t :: %__MODULE__{
            node_id: String.t() | nil,
            node_addr: String.t() | nil,
            running: boolean(),
            connected_peers: non_neg_integer(),
            relay_connected: boolean()
          }
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    # Use iroh's built-in default public relays (pass nil)
    # Can be overridden via IROH_RELAY_URL env var if needed
    relay_url = System.get_env("IROH_RELAY_URL")

    # Get bind_port from config (required for hole punching in Docker)
    bind_port = Application.get_env(:mydia, :p2p_bind_port)

    # Start the host - NIF returns {resource, node_id} directly (raises on error)
    {resource, node_id} = P2p.start_host(relay_url, bind_port)

    Logger.info(
      "P2P Host started with NodeID: #{node_id}, relay: #{relay_url || "(iroh defaults)"}"
    )

    if bind_port do
      Logger.info("P2P Host using UDP port #{bind_port}")
    else
      Logger.info("P2P Host using random port")
    end

    # Start listening for events, sending them to self()
    # NIF returns "ok" directly (raises on error)
    "ok" = P2p.start_listening(resource, self())

    state = %{
      resource: resource,
      node_id: node_id,
      node_addr: nil,
      relay_connected: false,
      # Track connected peers (MapSet of peer IDs)
      connected_peers: MapSet.new()
    }

    {:ok, state}
  end

  @doc """
  Dial a peer using their EndpointAddr JSON.
  """
  def dial(endpoint_addr_json) do
    GenServer.call(__MODULE__, {:dial, endpoint_addr_json})
  end

  @doc """
  Get the node ID (PublicKey) of this p2p host.
  """
  def node_id do
    GenServer.call(__MODULE__, :node_id)
  end

  @doc """
  Get this node's EndpointAddr as JSON for sharing with other peers.
  """
  def get_node_addr do
    GenServer.call(__MODULE__, :get_node_addr)
  end

  @doc """
  Get the current status of the p2p host.
  """
  @spec status() :: Status.t()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Get network statistics from the p2p host.
  """
  @spec network_stats() :: P2p.NetworkStats.t()
  def network_stats do
    GenServer.call(__MODULE__, :network_stats)
  end

  # GenServer callbacks

  def handle_call({:dial, endpoint_addr_json}, _from, state) do
    result = P2p.dial(state.resource, endpoint_addr_json)
    {:reply, result, state}
  end

  def handle_call(:node_id, _from, state) do
    {:reply, state.node_id, state}
  end

  def handle_call(:get_node_addr, _from, state) do
    node_addr = P2p.get_node_addr(state.resource)
    {:reply, node_addr, state}
  end

  def handle_call(:status, _from, state) do
    # Get relay_connected from NIF since the event may not be reliably sent
    network_stats = P2p.get_network_stats(state.resource)

    status = %Status{
      node_id: state.node_id,
      node_addr: state.node_addr,
      running: true,
      connected_peers: MapSet.size(state.connected_peers),
      relay_connected: network_stats.relay_connected
    }

    {:reply, status, state}
  end

  def handle_call(:network_stats, _from, state) do
    stats = P2p.get_network_stats(state.resource)
    {:reply, stats, state}
  end

  # Handle events from Rust NIF

  def handle_info({:ok, "peer_connected", peer_id}, state) do
    Logger.info("P2P Event: Peer Connected #{peer_id}")
    state = %{state | connected_peers: MapSet.put(state.connected_peers, peer_id)}
    {:noreply, state}
  end

  def handle_info({:ok, "peer_disconnected", peer_id}, state) do
    Logger.info("P2P Event: Peer Disconnected #{peer_id}")
    state = %{state | connected_peers: MapSet.delete(state.connected_peers, peer_id)}
    {:noreply, state}
  end

  def handle_info({:ok, "relay_connected"}, state) do
    Logger.info("P2P Event: Relay Connected")
    state = %{state | relay_connected: true}
    {:noreply, state}
  end

  def handle_info({:ok, "ready", node_addr}, state) do
    Logger.info("P2P Event: Ready with address")
    Logger.debug("Node address: #{node_addr}")
    state = %{state | node_addr: node_addr}
    {:noreply, state}
  end

  def handle_info({:ok, "request_received", "pairing", request_id, req}, state) do
    Logger.info("P2P Request: Pairing from #{req.device_name}")

    device_attrs = %{
      device_name: req.device_name,
      platform: req.device_type || req.device_os || "unknown"
    }

    # Get direct URLs from config for the client to use
    direct_urls =
      case Mydia.RemoteAccess.get_config() do
        {:ok, config} -> config.direct_urls || []
        _ -> []
      end

    response =
      case Pairing.complete_pairing(req.claim_code, device_attrs) do
        {:ok, _device, media_token, access_token, device_token} ->
          %P2p.PairingResponse{
            success: true,
            media_token: media_token,
            access_token: access_token,
            device_token: device_token,
            error: nil,
            direct_urls: direct_urls
          }

        {:error, reason} ->
          Logger.warning("Pairing failed: #{inspect(reason)}")

          %P2p.PairingResponse{
            success: false,
            error: inspect(reason)
          }
      end

    # Wrap in tagged enum tuple as expected by NIF
    response_enum = {:pairing, response}

    P2p.send_response(state.resource, request_id, response_enum)
    {:noreply, state}
  end

  def handle_info({:ok, "request_received", "ping", _request_id}, state) do
    Logger.debug("P2P Ping Request received")
    {:noreply, state}
  end

  def handle_info({:ok, "request_received", "read_media", request_id, req}, state) do
    # Validate file path exists
    # SECURITY: In production, verify path is within allowed directories!
    if File.exists?(req.file_path) do
      # Use the optimized NIF to read chunk and respond
      P2p.respond_with_file_chunk(
        state.resource,
        request_id,
        req.file_path,
        req.offset,
        req.length
      )
    else
      Logger.warning("Requested file not found: #{req.file_path}")
      P2p.send_response(state.resource, request_id, {:error, "File not found"})
    end

    {:noreply, state}
  end

  def handle_info({:ok, "request_received", "graphql", request_id, req}, state) do
    Logger.debug("P2P Request: GraphQL query")

    # Parse variables from JSON
    variables = parse_graphql_variables(req.variables)

    # Build context from auth token
    context = build_graphql_context(req.auth_token)

    # Execute the GraphQL query
    result =
      Absinthe.run(
        req.query,
        MydiaWeb.Schema,
        variables: variables,
        operation_name: req.operation_name,
        context: context
      )

    response =
      case result do
        {:ok, %{data: data, errors: errors}} ->
          %P2p.GraphQLResponse{
            data: encode_json(data),
            errors: encode_graphql_errors(errors)
          }

        {:ok, %{data: data}} ->
          %P2p.GraphQLResponse{
            data: encode_json(data),
            errors: nil
          }

        {:error, reason} ->
          Logger.warning("GraphQL execution failed: #{inspect(reason)}")

          %P2p.GraphQLResponse{
            data: nil,
            errors: encode_json([%{message: inspect(reason)}])
          }
      end

    P2p.send_response(state.resource, request_id, {:graphql, response})
    {:noreply, state}
  end

  def handle_info({:ok, "unknown_request"}, state) do
    Logger.debug("P2P: Unknown request type received")
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("P2P Unhandled Event: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private helpers for GraphQL handling

  defp parse_graphql_variables(nil), do: %{}

  defp parse_graphql_variables(variables_json) when is_binary(variables_json) do
    case Jason.decode(variables_json) do
      {:ok, variables} when is_map(variables) -> variables
      _ -> %{}
    end
  end

  defp build_graphql_context(nil), do: %{}

  defp build_graphql_context(auth_token) when is_binary(auth_token) do
    # Use Guardian to verify the token and get the user
    case Mydia.Auth.Guardian.verify_token(auth_token) do
      {:ok, user} ->
        %{current_user: user}

      {:error, _reason} ->
        Logger.debug("P2P GraphQL: Invalid auth token")
        %{}
    end
  end

  defp encode_json(nil), do: nil

  defp encode_json(data) do
    case Jason.encode(data) do
      {:ok, json} -> json
      {:error, _} -> nil
    end
  end

  defp encode_graphql_errors(nil), do: nil
  defp encode_graphql_errors([]), do: nil

  defp encode_graphql_errors(errors) when is_list(errors) do
    # Convert Absinthe errors to a JSON-serializable format
    serializable_errors =
      Enum.map(errors, fn error ->
        %{
          message: Map.get(error, :message, inspect(error)),
          locations: Map.get(error, :locations),
          path: Map.get(error, :path)
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()
      end)

    encode_json(serializable_errors)
  end
end
