defmodule Mydia.RemoteAccess.Relay do
  @moduledoc """
  GenServer that maintains a WebSocket connection to the metadata-relay service
  for NAT traversal when direct connections fail.

  This module uses a GenServer wrapper around WebSockex to provide reliable
  process registration. The GenServer is registered with a stable name while
  the WebSockex process runs internally without name registration.

  This module:
  - Registers the instance with the relay service on startup
  - Maintains a persistent connection with heartbeat/keep-alive
  - Handles incoming relayed connection requests
  - Auto-reconnects on disconnect
  - Gracefully handles relay service unavailability

  ## Relay Protocol

  The relay service uses JSON messages over WebSocket:

  - Registration: `{"type": "register", "instance_id": "uuid", "public_key": "base64"}`
  - Heartbeat: `{"type": "ping"}` / `{"type": "pong"}`
  - Incoming connection: `{"type": "connection", "session_id": "uuid", "client_public_key": "base64"}`
  """

  use GenServer
  require Logger

  alias Mydia.RemoteAccess

  # Heartbeat interval: 30 seconds (matches Phoenix Channel defaults)
  @heartbeat_interval 30_000

  # Heartbeat response timeout: 10 seconds
  # If no pong received within this time, connection is considered dead
  @heartbeat_timeout 10_000

  # Reconnect intervals with exponential backoff (in milliseconds)
  @initial_reconnect_delay 1_000
  @max_reconnect_delay 60_000

  # Client API

  @doc """
  Starts the relay connection GenServer.
  Returns {:ok, pid} or {:error, reason}.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    # Validate config before starting GenServer
    case get_relay_config() do
      {:ok, _config} ->
        GenServer.start_link(__MODULE__, opts, name: name)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns a specification to start this module under a supervisor.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Gets the current status of the relay connection.
  Returns {:ok, status} or {:error, :not_running}.

  Status map includes:
  - :connected - boolean
  - :registered - boolean
  - :instance_id - string
  - :relay_url - string
  - :public_key - base64-encoded public key
  """
  def status(server \\ __MODULE__) do
    try do
      GenServer.call(server, :status)
    catch
      :exit, {:noproc, _} ->
        {:error, :not_running}

      :exit, {:timeout, _} ->
        {:error, :timeout}
    end
  end

  @doc """
  Sends a manual ping to verify the connection.
  Returns :ok or {:error, reason}.
  """
  def ping(server \\ __MODULE__) do
    try do
      GenServer.cast(server, :ping)
    catch
      :exit, {:noproc, _} ->
        {:error, :not_running}
    end
  end

  @doc """
  Updates the instance's direct URLs with the relay service.
  This should be called when the instance's reachable URLs change.
  Returns :ok or {:error, reason}.
  """
  def update_direct_urls(server \\ __MODULE__, direct_urls) when is_list(direct_urls) do
    try do
      GenServer.cast(server, {:update_urls, direct_urls})
    catch
      :exit, {:noproc, _} ->
        {:error, :not_running}
    end
  end

  @doc """
  Manually triggers reconnection to the relay service.
  Returns :ok or {:error, reason}.
  """
  def reconnect(server \\ __MODULE__) do
    try do
      GenServer.cast(server, :reconnect)
    catch
      :exit, {:noproc, _} ->
        {:error, :not_running}
    end
  end

  @doc """
  Sends a message to a client through the relay tunnel.
  Used to forward responses back to the client via the relay.

  ## Parameters
  - session_id: The relay session identifier
  - payload: Binary message payload to send

  Returns :ok or {:error, reason}.
  """
  def send_relay_message(server \\ __MODULE__, session_id, payload) when is_binary(payload) do
    try do
      GenServer.cast(server, {:send_relay_message, session_id, payload})
    catch
      :exit, {:noproc, _} ->
        {:error, :not_running}
    end
  end

  @doc """
  Requests a claim code from the relay service.

  The relay generates the code and returns it. This allows remote clients
  to redeem the claim code through the relay to discover and connect to this instance.

  ## Parameters
  - user_id: The user ID associated with this claim
  - ttl_seconds: Time-to-live in seconds (default: 300)

  Returns {:ok, code, expires_at} if successful, {:error, reason} otherwise.
  """
  def request_claim(user_id, ttl_seconds \\ 300) do
    request_claim(__MODULE__, user_id, ttl_seconds)
  end

  @doc """
  Requests a claim code from a specific relay server.

  See `request_claim/2` for details.
  """
  def request_claim(server, user_id, ttl_seconds) do
    Logger.debug("Relay.request_claim: user_id=#{user_id}, ttl=#{ttl_seconds}s")

    try do
      GenServer.call(server, {:request_claim, user_id, ttl_seconds}, 10_000)
    catch
      :exit, {:noproc, _} ->
        Logger.warning("Relay.request_claim: GenServer not running")
        {:error, :not_running}

      :exit, {:timeout, _} ->
        Logger.warning("Relay.request_claim: GenServer call timeout")
        {:error, :timeout}
    end
  end

  # GenServer Callbacks

  @impl GenServer
  def init(_opts) do
    # Config is already validated in start_link, but we need to fetch it again
    {:ok, config} = get_relay_config()

    # Read relay URL from environment variable, not database
    base_url = Mydia.Metadata.metadata_relay_url()
    instance_id = config.instance_id
    public_key = config.static_public_key

    # Convert ws:// or wss:// URL format if needed
    url = normalize_relay_url(base_url)

    # Get direct URLs from config, or auto-detect if empty
    direct_urls =
      case Map.get(config, :direct_urls, []) do
        [] ->
          Logger.info("No direct URLs configured, auto-detecting local IPs...")
          Mydia.RemoteAccess.DirectUrls.detect_all()

        urls ->
          urls
      end

    Logger.info("Direct URLs for relay registration: #{inspect(direct_urls)}")

    state = %{
      instance_id: instance_id,
      public_key: public_key,
      relay_url: url,
      direct_urls: direct_urls,
      connected: false,
      registered: false,
      ws_pid: nil,
      heartbeat_timer: nil,
      heartbeat_timeout_ref: nil,
      pending_heartbeat: false,
      reconnect_delay: @initial_reconnect_delay,
      pending_claims: %{}
    }

    Logger.info("Relay GenServer starting, will connect to #{url}")

    # Start WebSocket connection asynchronously
    send(self(), :connect)

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    status = %{
      connected: state.connected,
      registered: state.registered,
      instance_id: state.instance_id,
      relay_url: state.relay_url,
      public_key: Base.encode64(state.public_key)
    }

    {:reply, {:ok, status}, state}
  end

  @impl GenServer
  def handle_call({:request_claim, user_id, ttl_seconds}, from, state) do
    if state.registered and state.ws_pid do
      # Generate a unique request ID to match the response
      request_id = :erlang.unique_integer([:positive]) |> Integer.to_string()

      msg =
        Jason.encode!(%{
          type: "create_claim",
          user_id: user_id,
          ttl_seconds: ttl_seconds,
          request_id: request_id
        })

      case WebSockex.send_frame(state.ws_pid, {:text, msg}) do
        :ok ->
          Logger.info("Sent create_claim request to relay (request_id: #{request_id})")
          # Store the pending request to reply later
          pending = Map.put(state.pending_claims, request_id, from)
          {:noreply, %{state | pending_claims: pending}}

        {:error, reason} ->
          Logger.warning("Failed to send claim request: #{inspect(reason)}")
          {:reply, {:error, :send_failed}, state}
      end
    else
      Logger.warning(
        "Cannot request claim: not registered with relay (connected: #{state.connected}, registered: #{state.registered})"
      )

      {:reply, {:error, :not_registered}, state}
    end
  end

  @impl GenServer
  def handle_cast(:ping, state) do
    if state.ws_pid do
      msg = Jason.encode!(%{type: "ping"})
      WebSockex.send_frame(state.ws_pid, {:text, msg})
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:update_urls, direct_urls}, state) do
    state = %{state | direct_urls: direct_urls}

    if state.ws_pid do
      msg = Jason.encode!(%{type: "update_urls", direct_urls: direct_urls})
      WebSockex.send_frame(state.ws_pid, {:text, msg})
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast(:reconnect, state) do
    Logger.info("Manual reconnection requested")
    state = disconnect(state)
    send(self(), :connect)
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:send_relay_message, session_id, payload}, state) do
    # Parse payload to get message info
    message_info =
      case Jason.decode(payload) do
        {:ok, %{"type" => msg_type, "status" => status}} ->
          "type=#{msg_type}, status=#{status}"

        {:ok, %{"type" => msg_type}} ->
          "type=#{msg_type}"

        _ ->
          "binary"
      end

    Logger.info(
      "Relay sending message to client: session=#{session_id}, #{message_info}, payload_size=#{byte_size(payload)}"
    )

    if state.ws_pid do
      msg =
        Jason.encode!(%{
          type: "relay_message",
          session_id: session_id,
          payload: Base.encode64(payload)
        })

      Logger.info("Relay WebSocket frame sent: session=#{session_id}, frame_size=#{byte_size(msg)}")
      WebSockex.send_frame(state.ws_pid, {:text, msg})
    else
      Logger.warning("Cannot send relay_message: ws_pid is nil, session=#{session_id}")
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:connect, state) do
    Logger.info("Connecting to relay service at #{state.relay_url}")

    case Mydia.RemoteAccess.Relay.WebSocket.start_link(
           url: state.relay_url,
           parent: self()
         ) do
      {:ok, ws_pid} ->
        # Monitor the WebSocket process
        Process.monitor(ws_pid)
        Logger.info("WebSocket process started: #{inspect(ws_pid)}")
        {:noreply, %{state | ws_pid: ws_pid, reconnect_delay: @initial_reconnect_delay}}

      {:error, reason} ->
        Logger.warning("Failed to start WebSocket: #{inspect(reason)}")
        schedule_reconnect(state)
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(:heartbeat, state) do
    if state.ws_pid && state.connected do
      msg = Jason.encode!(%{type: "ping"})
      WebSockex.send_frame(state.ws_pid, {:text, msg})

      # Schedule heartbeat response timeout
      timeout_ref = Process.send_after(self(), :heartbeat_timeout, @heartbeat_timeout)

      {:noreply, %{state | pending_heartbeat: true, heartbeat_timeout_ref: timeout_ref}}
    else
      # Not connected, schedule next heartbeat attempt
      timer = Process.send_after(self(), :heartbeat, @heartbeat_interval)
      {:noreply, %{state | heartbeat_timer: timer}}
    end
  end

  @impl GenServer
  def handle_info(:heartbeat_timeout, %{pending_heartbeat: true} = state) do
    Logger.warning(
      "Heartbeat timeout - no pong received within #{@heartbeat_timeout}ms, reconnecting"
    )

    state = handle_disconnect(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:heartbeat_timeout, state) do
    # Heartbeat was already acknowledged, ignore stale timeout
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:send_registration, state) do
    if state.ws_pid do
      registration_msg =
        Jason.encode!(%{
          type: "register",
          instance_id: state.instance_id,
          public_key: Base.encode64(state.public_key),
          direct_urls: state.direct_urls
        })

      Logger.info("Sending registration message to relay")
      WebSockex.send_frame(state.ws_pid, {:text, registration_msg})
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:ws_connected, ws_pid}, state) when ws_pid == state.ws_pid do
    Logger.info("Connected to relay service at #{state.relay_url}")

    # Send registration
    send(self(), :send_registration)

    # Start heartbeat
    timer = Process.send_after(self(), :heartbeat, @heartbeat_interval)

    {:noreply, %{state | connected: true, heartbeat_timer: timer}}
  end

  @impl GenServer
  def handle_info({:ws_frame, ws_pid, {:text, msg}}, state) when ws_pid == state.ws_pid do
    case Jason.decode(msg) do
      {:ok, data} ->
        state = handle_relay_message(data, state)
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("Failed to decode relay message: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:ws_disconnected, ws_pid, reason}, state) when ws_pid == state.ws_pid do
    Logger.warning("WebSocket disconnected: #{inspect(reason)}")
    state = handle_disconnect(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, ws_pid, reason}, state) when ws_pid == state.ws_pid do
    Logger.warning("WebSocket process died: #{inspect(reason)}")
    state = handle_disconnect(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Ignore DOWN messages for other processes
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.info("Relay received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.info("Relay GenServer terminating: #{inspect(reason)}")
    disconnect(state)
    :ok
  end

  # Private Functions

  defp handle_relay_message(%{"type" => "registered"}, state) do
    Logger.info("Successfully registered with relay service")
    %{state | registered: true}
  end

  defp handle_relay_message(%{"type" => "pong"}, state) do
    # Heartbeat acknowledged - cancel timeout and schedule next heartbeat
    if state.heartbeat_timeout_ref do
      Process.cancel_timer(state.heartbeat_timeout_ref)
    end

    timer = Process.send_after(self(), :heartbeat, @heartbeat_interval)

    %{state | pending_heartbeat: false, heartbeat_timeout_ref: nil, heartbeat_timer: timer}
  end

  defp handle_relay_message(
         %{
           "type" => "connection",
           "session_id" => session_id
         } = msg,
         state
       ) do
    has_public_key = msg["client_public_key"] != nil && msg["client_public_key"] != ""

    Logger.info(
      "Relay received connection request: session=#{session_id}, has_client_public_key=#{has_public_key}"
    )

    # Client public key is optional - it will be established during Noise handshake
    client_public_key =
      case msg["client_public_key"] do
        nil ->
          <<>>

        "" ->
          <<>>

        client_key ->
          case Base.decode64(client_key) do
            {:ok, key} -> key
            :error -> <<>>
          end
      end

    # Broadcast relay connection event to the tunnel supervisor
    Logger.info(
      "Relay accepting connection: session=#{session_id}, client_public_key_length=#{byte_size(client_public_key)}, broadcasting to relay:connections"
    )

    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      "relay:connections",
      {:relay_connection, session_id, client_public_key, self()}
    )

    Logger.info("Relay broadcast sent for session #{session_id}")
    state
  end

  defp handle_relay_message(
         %{"type" => "relay_message", "session_id" => session_id, "payload" => payload_b64},
         state
       ) do
    # Forward relayed message to the appropriate session
    case Base.decode64(payload_b64) do
      {:ok, payload} ->
        # Try to parse and log message type for debugging
        message_info =
          case Jason.decode(payload) do
            {:ok, %{"type" => msg_type} = msg} ->
              extra =
                case msg_type do
                  "request" ->
                    ", method=#{msg["method"]}, path=#{msg["path"]}, id=#{msg["id"]}"

                  "pairing_handshake" ->
                    ", initiating pairing"

                  "handshake_init" ->
                    ", initiating reconnection handshake"

                  "claim_code" ->
                    ", claiming code=#{msg["data"]["code"] || msg["code"]}"

                  _ ->
                    ""
                end

              "type=#{msg_type}#{extra}"

            _ ->
              "binary data"
          end

        Logger.info(
          "Received relay_message for session #{session_id}: #{message_info}, payload_size=#{byte_size(payload)}"
        )

        Phoenix.PubSub.broadcast(
          Mydia.PubSub,
          "relay:session:#{session_id}",
          {:relay_message, payload}
        )

      :error ->
        Logger.warning("Invalid base64 payload in relay message for session #{session_id}")
    end

    state
  end

  defp handle_relay_message(%{"type" => "error", "message" => error_msg}, state) do
    Logger.error("Relay service error: #{error_msg}")
    state
  end

  defp handle_relay_message(
         %{"type" => "claim_created", "code" => code, "expires_at" => expires_at} = msg,
         state
       ) do
    Logger.info("Claim created by relay: #{code}")

    # Find and reply to the pending request
    case msg["request_id"] do
      nil ->
        # Legacy: broadcast to topic
        Phoenix.PubSub.broadcast(
          Mydia.PubSub,
          "relay:claim:#{code}",
          {:claim_created, code, expires_at}
        )

        state

      request_id ->
        case Map.pop(state.pending_claims, request_id) do
          {nil, _pending} ->
            Logger.warning("Received claim_created for unknown request_id: #{request_id}")
            state

          {from, pending} ->
            GenServer.reply(from, {:ok, code, expires_at})
            %{state | pending_claims: pending}
        end
    end
  end

  defp handle_relay_message(msg, state) do
    Logger.info("Relay received unhandled message type: #{msg["type"] || "unknown"}")
    state
  end

  defp handle_disconnect(state) do
    # Cancel heartbeat timer
    if state.heartbeat_timer do
      Process.cancel_timer(state.heartbeat_timer)
    end

    # Cancel heartbeat timeout timer
    if state.heartbeat_timeout_ref do
      Process.cancel_timer(state.heartbeat_timeout_ref)
    end

    # Reply to any pending claims with error
    Enum.each(state.pending_claims, fn {_request_id, from} ->
      GenServer.reply(from, {:error, :disconnected})
    end)

    # Calculate reconnect delay with exponential backoff
    schedule_reconnect(state)

    %{
      state
      | connected: false,
        registered: false,
        ws_pid: nil,
        heartbeat_timer: nil,
        heartbeat_timeout_ref: nil,
        pending_heartbeat: false,
        pending_claims: %{}
    }
  end

  defp disconnect(state) do
    # Stop WebSocket if running
    if state.ws_pid && Process.alive?(state.ws_pid) do
      Process.exit(state.ws_pid, :shutdown)
    end

    # Cancel heartbeat timer
    if state.heartbeat_timer do
      Process.cancel_timer(state.heartbeat_timer)
    end

    # Cancel heartbeat timeout timer
    if state.heartbeat_timeout_ref do
      Process.cancel_timer(state.heartbeat_timeout_ref)
    end

    %{
      state
      | connected: false,
        registered: false,
        ws_pid: nil,
        heartbeat_timer: nil,
        heartbeat_timeout_ref: nil,
        pending_heartbeat: false
    }
  end

  defp schedule_reconnect(state) do
    delay = min(state.reconnect_delay, @max_reconnect_delay)
    next_delay = min(state.reconnect_delay * 2, @max_reconnect_delay)

    Logger.info("Scheduling reconnect to relay in #{delay}ms...")
    Process.send_after(self(), :connect, delay)

    %{state | reconnect_delay: next_delay}
  end

  defp get_relay_config do
    case RemoteAccess.get_config() do
      nil ->
        {:error, :remote_access_not_configured}

      config ->
        if config.enabled do
          {:ok, config}
        else
          {:error, :remote_access_disabled}
        end
    end
  end

  defp normalize_relay_url(url) do
    # Convert http:// to ws:// and https:// to wss://, then append /relay/tunnel path
    base_url =
      cond do
        String.starts_with?(url, "https://") ->
          String.replace(url, "https://", "wss://")

        String.starts_with?(url, "http://") ->
          String.replace(url, "http://", "ws://")

        String.starts_with?(url, "ws://") or String.starts_with?(url, "wss://") ->
          url

        true ->
          # Default to wss:// if no protocol specified
          "wss://#{url}"
      end

    # Append the relay tunnel WebSocket path
    base_url
    |> String.trim_trailing("/")
    |> Kernel.<>("/relay/tunnel/websocket")
  end
end
