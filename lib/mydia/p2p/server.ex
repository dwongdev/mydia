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
  alias Mydia.Streaming.HlsSession
  alias MydiaWeb.Schema.Middleware.Logging, as: GraphQLLogging

  @doc """
  Status information about the p2p host.
  """
  defmodule Status do
    defstruct [
      :node_id,
      :node_addr,
      :running,
      :connected_peers,
      :relay_connected,
      :relay_url
    ]

    @type t :: %__MODULE__{
            node_id: String.t() | nil,
            node_addr: String.t() | nil,
            running: boolean(),
            connected_peers: non_neg_integer(),
            relay_connected: boolean(),
            relay_url: String.t() | nil
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

    # Get keypair_path from config for persistent node identity
    # This is REQUIRED - without it, the node ID changes on restart and paired devices can't reconnect
    keypair_path =
      Application.get_env(:mydia, :p2p_keypair_path) ||
        raise """
        P2P keypair path not configured!

        The p2p_keypair_path config is required for persistent node identity.
        Without it, paired devices will not be able to reconnect after server restart.

        Add to your config:

            config :mydia, :p2p_keypair_path, "/path/to/p2p_keypair.bin"

        Or set the P2P_KEYPAIR_PATH environment variable.
        """

    # Start the host - NIF returns {resource, node_id} directly (raises on error)
    {resource, node_id} = P2p.start_host(relay_url, bind_port, keypair_path)

    Logger.info(
      "P2P Host started with NodeID: #{node_id}, relay: #{relay_url || "(iroh defaults)"}"
    )

    Logger.info("P2P Host using persistent keypair at #{keypair_path}")

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

    # Try to get relay_url from network_stats first, fallback to extracting from node_addr
    relay_url = network_stats.relay_url || extract_relay_url_from_node_addr(state.node_addr)

    status = %Status{
      node_id: state.node_id,
      node_addr: state.node_addr,
      running: true,
      connected_peers: MapSet.size(state.connected_peers),
      relay_connected: network_stats.relay_connected,
      relay_url: relay_url
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

    # Build context from auth token, marking source as p2p
    context = build_graphql_context(req.auth_token, :p2p)

    # Execute the GraphQL query with logging
    result =
      GraphQLLogging.run(
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

        # Query validation errors (no data key, only errors)
        {:ok, %{errors: errors}} ->
          Logger.warning("GraphQL validation error: #{inspect(errors)}")

          %P2p.GraphQLResponse{
            data: nil,
            errors: encode_graphql_errors(errors)
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

  def handle_info({:ok, "hls_stream", stream_id, req}, state) do
    Logger.debug("P2P Request: HLS stream session=#{req.session_id} path=#{req.path}")

    # Spawn a task to handle the streaming so we don't block the GenServer
    Task.start(fn ->
      handle_hls_stream(state.resource, stream_id, req)
    end)

    {:noreply, state}
  end

  def handle_info({:ok, "request_received", "blob_download", request_id, req}, state) do
    Logger.info("P2P Request: Blob download for job #{req.job_id}")

    # Spawn a task to handle the blob ticket creation so we don't block the GenServer
    resource = state.resource

    Task.start(fn ->
      handle_blob_download(resource, request_id, req)
    end)

    {:noreply, state}
  end

  # Handle Rust/iroh log messages
  def handle_info({:ok, "log", level, target, message}, state) do
    # Forward Rust logs to Elixir Logger with appropriate level
    log_message = "[#{target}] #{message}"

    case level do
      "trace" -> Logger.debug(log_message, rust_target: target)
      "debug" -> Logger.debug(log_message, rust_target: target)
      "info" -> Logger.info(log_message, rust_target: target)
      "warn" -> Logger.warning(log_message, rust_target: target)
      "error" -> Logger.error(log_message, rust_target: target)
      _ -> Logger.debug(log_message, rust_target: target)
    end

    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("P2P Unhandled Event: #{inspect(msg)}")
    {:noreply, state}
  end

  # HLS streaming handler

  # Chunk size for streaming (32KB)
  @hls_chunk_size 32 * 1024

  defp handle_hls_stream(resource, stream_id, req) do
    # Verify auth token
    case verify_hls_auth(req.auth_token) do
      {:ok, _user} ->
        # Look up the session by session_id
        case lookup_hls_session(req.session_id) do
          {:ok, pid, session_info} ->
            # Wait for the session to be ready (FFmpeg has created initial files)
            case HlsSession.await_ready(pid, 30_000) do
              :ok ->
                # Build the file path
                file_path = Path.join(session_info.temp_dir, req.path)

                # Security check: ensure path is within temp_dir
                case validate_path(file_path, session_info.temp_dir) do
                  :ok ->
                    stream_hls_file(resource, stream_id, file_path, req)

                  {:error, reason} ->
                    Logger.warning("HLS path validation failed: #{inspect(reason)}")
                    send_hls_error(resource, stream_id, 403, "Forbidden")
                end

              {:error, :timeout} ->
                Logger.warning("HLS session #{req.session_id} not ready after timeout")
                send_hls_error(resource, stream_id, 503, "Transcoding not ready")
            end

          {:error, :not_found} ->
            Logger.warning("HLS session not found: #{req.session_id}")
            send_hls_error(resource, stream_id, 404, "Session not found")
        end

      {:error, _reason} ->
        Logger.warning("HLS auth failed")
        send_hls_error(resource, stream_id, 401, "Unauthorized")
    end
  end

  defp verify_hls_auth(nil), do: {:error, :no_token}

  defp verify_hls_auth(auth_token) when is_binary(auth_token) do
    Mydia.Auth.Guardian.verify_token(auth_token)
  end

  defp lookup_hls_session(session_id) do
    case Registry.lookup(Mydia.Streaming.HlsSessionRegistry, {:session, session_id}) do
      [{pid, info}] ->
        # Trigger heartbeat to keep session alive
        HlsSession.heartbeat(pid)
        {:ok, pid, info}

      [] ->
        {:error, :not_found}
    end
  end

  defp validate_path(requested_path, base_dir) do
    # Expand both paths to handle .. and symlinks
    expanded_requested = Path.expand(requested_path)
    expanded_base = Path.expand(base_dir)

    if String.starts_with?(expanded_requested, expanded_base) do
      :ok
    else
      {:error, :path_traversal}
    end
  end

  defp stream_hls_file(resource, stream_id, file_path, req) do
    try do
      do_stream_hls_file(resource, stream_id, file_path, req)
    rescue
      e in ArgumentError ->
        Logger.error("HLS stream failed for #{file_path}: #{Exception.message(e)}")

        :ok
    end
  end

  defp do_stream_hls_file(resource, stream_id, file_path, req) do
    case File.stat(file_path) do
      {:ok, %File.Stat{size: file_size}} ->
        # Determine content type
        content_type = hls_content_type(file_path)

        # Handle range requests
        case parse_range(req.range_start, req.range_end, file_size) do
          {:full, _} ->
            # Full file request
            send_full_hls_file(resource, stream_id, file_path, file_size, content_type)

          {:partial, range_start, range_end, content_length} ->
            # Partial content (206)
            send_partial_hls_file(
              resource,
              stream_id,
              file_path,
              file_size,
              range_start,
              range_end,
              content_length,
              content_type
            )
        end

      {:error, :enoent} ->
        Logger.debug("HLS file not found: #{file_path}")
        send_hls_error(resource, stream_id, 404, "Not found")

      {:error, reason} ->
        Logger.warning("HLS file error: #{inspect(reason)}")
        send_hls_error(resource, stream_id, 500, "Internal error")
    end
  end

  defp hls_content_type(path) do
    case Path.extname(path) do
      ".m3u8" -> "application/vnd.apple.mpegurl"
      ".ts" -> "video/mp2t"
      ".mp4" -> "video/mp4"
      ".m4s" -> "video/iso.segment"
      ".vtt" -> "text/vtt"
      _ -> "application/octet-stream"
    end
  end

  defp parse_range(nil, nil, file_size), do: {:full, file_size}

  defp parse_range(range_start, range_end, file_size) do
    # Calculate actual range
    start_byte = range_start || 0
    end_byte = min(range_end || file_size - 1, file_size - 1)
    content_length = end_byte - start_byte + 1

    {:partial, start_byte, end_byte, content_length}
  end

  defp send_full_hls_file(resource, stream_id, file_path, file_size, content_type) do
    # Send header
    header = %P2p.HlsResponseHeader{
      status: 200,
      content_type: content_type,
      content_length: file_size,
      content_range: nil,
      cache_control: hls_cache_control(file_path)
    }

    case P2p.send_hls_header(resource, stream_id, header) do
      "ok" ->
        # Stream the file in chunks
        stream_file_chunks(resource, stream_id, file_path, 0, file_size)
        P2p.finish_hls_stream(resource, stream_id)

      {:error, reason} ->
        Logger.error("Failed to send HLS header: #{inspect(reason)}")
    end
  end

  defp send_partial_hls_file(
         resource,
         stream_id,
         file_path,
         file_size,
         range_start,
         range_end,
         content_length,
         content_type
       ) do
    # Send header with 206 status
    header = %P2p.HlsResponseHeader{
      status: 206,
      content_type: content_type,
      content_length: content_length,
      content_range: "bytes #{range_start}-#{range_end}/#{file_size}",
      cache_control: hls_cache_control(file_path)
    }

    case P2p.send_hls_header(resource, stream_id, header) do
      "ok" ->
        # Stream the file portion in chunks
        stream_file_chunks(resource, stream_id, file_path, range_start, content_length)
        P2p.finish_hls_stream(resource, stream_id)

      {:error, reason} ->
        Logger.error("Failed to send HLS header: #{inspect(reason)}")
    end
  end

  defp stream_file_chunks(resource, stream_id, file_path, offset, remaining) do
    case File.open(file_path, [:read, :binary]) do
      {:ok, file} ->
        try do
          # Seek to offset
          {:ok, _} = :file.position(file, offset)

          # Stream chunks
          do_stream_chunks(resource, stream_id, file, remaining)
        after
          File.close(file)
        end

      {:error, reason} ->
        Logger.error("Failed to open file for streaming: #{inspect(reason)}")
    end
  end

  defp do_stream_chunks(_resource, _stream_id, _file, remaining) when remaining <= 0 do
    :ok
  end

  defp do_stream_chunks(resource, stream_id, file, remaining) do
    bytes_to_read = min(@hls_chunk_size, remaining)

    case IO.binread(file, bytes_to_read) do
      data when is_binary(data) ->
        case P2p.send_hls_chunk(resource, stream_id, data) do
          "ok" ->
            do_stream_chunks(resource, stream_id, file, remaining - byte_size(data))

          {:error, reason} ->
            Logger.error("Failed to send HLS chunk: #{inspect(reason)}")
        end

      :eof ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to read file chunk: #{inspect(reason)}")
    end
  end

  defp send_hls_error(resource, stream_id, status, message) do
    # Send error as header-only response
    # Wrapped in try/rescue because the P2P stream may already be closed
    # (e.g. peer disconnected), causing NIF calls to raise ArgumentError
    header = %P2p.HlsResponseHeader{
      status: status,
      content_type: "text/plain",
      content_length: byte_size(message),
      content_range: nil,
      cache_control: nil
    }

    try do
      case P2p.send_hls_header(resource, stream_id, header) do
        "ok" ->
          P2p.send_hls_chunk(resource, stream_id, message)
          P2p.finish_hls_stream(resource, stream_id)

        _ ->
          :ok
      end
    rescue
      e ->
        Logger.debug("Failed to send HLS error response: #{inspect(e)}")
        :ok
    end
  end

  defp hls_cache_control(path) do
    case Path.extname(path) do
      # Playlists should not be cached (may update)
      ".m3u8" -> "no-cache"
      # Segments can be cached longer
      ".ts" -> "max-age=86400"
      _ -> nil
    end
  end

  # Private helpers for GraphQL handling

  defp parse_graphql_variables(nil), do: %{}

  defp parse_graphql_variables(variables_json) when is_binary(variables_json) do
    case Jason.decode(variables_json) do
      {:ok, variables} when is_map(variables) -> variables
      _ -> %{}
    end
  end

  defp build_graphql_context(nil, source), do: %{source: source}

  defp build_graphql_context(auth_token, source) when is_binary(auth_token) do
    # Use Guardian to verify the token and get the user
    case Mydia.Auth.Guardian.verify_token(auth_token) do
      {:ok, user} ->
        %{current_user: user, source: source}

      {:error, _reason} ->
        Logger.debug("P2P GraphQL: Invalid auth token")
        %{source: source}
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

  # Extract the relay URL from the node_addr JSON
  # The node_addr is a JSON object like:
  # {"id": "...", "addrs": [{"Relay": "https://..."}, {"Ip": "1.2.3.4:5678"}]}
  defp extract_relay_url_from_node_addr(nil), do: nil

  defp extract_relay_url_from_node_addr(node_addr_json) when is_binary(node_addr_json) do
    case Jason.decode(node_addr_json) do
      {:ok, %{"addrs" => addrs}} when is_list(addrs) ->
        # Find the first Relay address
        Enum.find_value(addrs, fn
          %{"Relay" => relay_url} -> relay_url
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  # Blob download handler

  defp handle_blob_download(resource, request_id, req) do
    # Verify auth token
    case verify_blob_auth(req.auth_token) do
      {:ok, _user} ->
        # Look up the transcode job by job_id
        case lookup_transcode_job(req.job_id) do
          {:ok, job} ->
            create_and_send_blob_ticket(resource, request_id, job)

          {:error, :not_found} ->
            Logger.warning("Blob download: Job not found: #{req.job_id}")
            send_blob_error(resource, request_id, "Job not found")

          {:error, :not_ready} ->
            Logger.warning("Blob download: Job not ready: #{req.job_id}")
            send_blob_error(resource, request_id, "Job not ready")
        end

      {:error, _reason} ->
        Logger.warning("Blob download: Auth failed")
        send_blob_error(resource, request_id, "Unauthorized")
    end
  end

  defp verify_blob_auth(nil), do: {:error, :no_token}

  defp verify_blob_auth(auth_token) when is_binary(auth_token) do
    Mydia.Auth.Guardian.verify_token(auth_token)
  end

  defp lookup_transcode_job(job_id) do
    alias Mydia.Downloads.TranscodeJob
    alias Mydia.Repo

    # Look up the transcode job by ID, preloading related media for filename generation
    case Repo.get(TranscodeJob, job_id) |> Repo.preload(media_file: [:movie, episode: :show]) do
      nil ->
        {:error, :not_found}

      job ->
        # Check if the job is ready (transcoding complete)
        if (job.status == "ready" and job.output_path) && File.exists?(job.output_path) do
          {:ok, job}
        else
          {:error, :not_ready}
        end
    end
  end

  defp create_and_send_blob_ticket(resource, request_id, job) do
    # Generate a filename from the job
    filename = generate_download_filename(job)

    # Create the blob ticket using the NIF
    case P2p.create_blob_ticket(job.output_path, filename) do
      ticket when is_binary(ticket) ->
        # Parse the ticket to get file_size
        {:ok, ticket_data} = Jason.decode(ticket)
        file_size = Map.get(ticket_data, "file_size")

        response = %P2p.BlobDownloadResponse{
          success: true,
          ticket: ticket,
          filename: filename,
          file_size: file_size,
          error: nil
        }

        P2p.send_response(resource, request_id, {:blob_download, response})

      {:error, reason} ->
        Logger.error("Failed to create blob ticket: #{inspect(reason)}")
        send_blob_error(resource, request_id, "Failed to create download ticket")
    end
  end

  defp send_blob_error(resource, request_id, error_message) do
    response = %P2p.BlobDownloadResponse{
      success: false,
      ticket: nil,
      filename: nil,
      file_size: nil,
      error: error_message
    }

    P2p.send_response(resource, request_id, {:blob_download, response})
  end

  defp generate_download_filename(job) do
    # Generate a sensible filename based on the job content
    # Format: Title_Resolution.mp4
    # Job has media_file which may have movie or episode association
    base_name =
      case job.media_file do
        %{movie: %{title: title}} when not is_nil(title) ->
          sanitize_filename(title)

        %{episode: %{show: %{name: show_name}, season_number: season, episode_number: ep}}
        when not is_nil(show_name) ->
          "#{sanitize_filename(show_name)}_S#{pad_number(season)}E#{pad_number(ep)}"

        _ ->
          "download"
      end

    resolution = job.resolution || "unknown"
    "#{base_name}_#{resolution}.mp4"
  end

  defp sanitize_filename(name) do
    name
    |> String.replace(~r/[^\w\s-]/, "")
    |> String.replace(~r/\s+/, "_")
    |> String.slice(0, 100)
  end

  defp pad_number(num) when is_integer(num),
    do: String.pad_leading(Integer.to_string(num), 2, "0")

  defp pad_number(_), do: "00"
end
