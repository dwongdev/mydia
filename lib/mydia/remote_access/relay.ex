defmodule Mydia.RemoteAccess.Relay do
  @moduledoc """
  GenServer that maintains a WebSocket connection to the metadata-relay service
  for NAT traversal when direct connections fail.

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

  use WebSockex
  require Logger

  alias Mydia.RemoteAccess

  # Heartbeat interval: 30 seconds
  @heartbeat_interval 30_000

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

    case get_relay_config() do
      {:ok, config} ->
        # Read relay URL from environment variable, not database
        url = Mydia.Metadata.metadata_relay_url()
        instance_id = config.instance_id
        public_key = config.static_public_key

        # Convert ws:// or wss:// URL format if needed
        url = normalize_relay_url(url)

        # Get direct URLs from config
        direct_urls = Map.get(config, :direct_urls, [])

        state = %{
          instance_id: instance_id,
          public_key: public_key,
          relay_url: url,
          direct_urls: direct_urls,
          registered: false,
          heartbeat_timer: nil,
          reconnect_delay: @initial_reconnect_delay
        }

        WebSockex.start_link(url, __MODULE__, state, name: name)

      {:error, :not_configured} ->
        {:error, :remote_access_not_configured}

      {:error, :disabled} ->
        {:error, :remote_access_disabled}
    end
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
  def status(pid \\ __MODULE__) do
    try do
      state = :sys.get_state(pid)

      {:ok,
       %{
         connected: true,
         registered: state.registered,
         instance_id: state.instance_id,
         relay_url: state.relay_url,
         public_key: Base.encode64(state.public_key)
       }}
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
  def ping(pid \\ __MODULE__) do
    safe_cast(pid, :ping)
  end

  @doc """
  Updates the instance's direct URLs with the relay service.
  This should be called when the instance's reachable URLs change.
  Returns :ok or {:error, reason}.
  """
  def update_direct_urls(pid \\ __MODULE__, direct_urls) when is_list(direct_urls) do
    safe_cast(pid, {:update_urls, direct_urls})
  end

  @doc """
  Manually triggers reconnection to the relay service.
  Returns :ok or {:error, reason}.
  """
  def reconnect(pid \\ __MODULE__) do
    safe_cast(pid, :reconnect)
  end

  @doc """
  Sends a message to a client through the relay tunnel.
  Used to forward responses back to the client via the relay.

  ## Parameters
  - session_id: The relay session identifier
  - payload: Binary message payload to send

  Returns :ok or {:error, reason}.
  """
  def send_relay_message(pid \\ __MODULE__, session_id, payload) when is_binary(payload) do
    safe_cast(pid, {:send_relay_message, session_id, payload})
  end

  @doc """
  Registers a claim code with the relay service.

  This allows remote clients to redeem the claim code through the relay
  to discover and connect to this instance.

  ## Parameters
  - pid: The relay process (default: __MODULE__)
  - user_id: The user ID associated with this claim
  - code: The claim code (e.g., "ABCD-1234")
  - ttl_seconds: Time-to-live in seconds (default: 300)

  Returns :ok if the claim was registered, {:error, reason} otherwise.
  """
  def create_claim(pid \\ __MODULE__, user_id, code, ttl_seconds \\ 300) do
    # Subscribe to get the confirmation
    topic = "relay:claim:#{code}"
    Phoenix.PubSub.subscribe(Mydia.PubSub, topic)

    # Send the request
    case safe_cast(pid, {:create_claim, user_id, code, ttl_seconds}) do
      :ok ->
        # Wait for confirmation with timeout
        receive do
          {:claim_created, ^code, _expires_at} ->
            Phoenix.PubSub.unsubscribe(Mydia.PubSub, topic)
            :ok
        after
          5_000 ->
            Phoenix.PubSub.unsubscribe(Mydia.PubSub, topic)
            Logger.warning("Timeout waiting for claim confirmation from relay")
            {:error, :timeout}
        end

      error ->
        Phoenix.PubSub.unsubscribe(Mydia.PubSub, topic)
        error
    end
  end

  # Safely casts a message to the WebSockex process, returning an error if the process isn't running.
  defp safe_cast(pid, message) do
    try do
      WebSockex.cast(pid, message)
    rescue
      ArgumentError ->
        {:error, :not_running}
    catch
      :exit, {:noproc, _} ->
        {:error, :not_running}

      :exit, {:timeout, _} ->
        {:error, :timeout}
    end
  end

  # WebSockex Callbacks

  @impl WebSockex
  def handle_connect(_conn, state) do
    Logger.info("Connected to relay service at #{state.relay_url}")

    # Schedule registration to be sent immediately
    send(self(), :send_registration)

    # Schedule first heartbeat
    timer = Process.send_after(self(), :heartbeat, @heartbeat_interval)

    # Reset reconnect delay on successful connection
    state = %{state | heartbeat_timer: timer, reconnect_delay: @initial_reconnect_delay}

    {:ok, state}
  end

  @impl WebSockex
  def handle_info(:send_registration, state) do
    # Send registration message with direct URLs
    registration_msg =
      Jason.encode!(%{
        type: "register",
        instance_id: state.instance_id,
        public_key: Base.encode64(state.public_key),
        direct_urls: state.direct_urls
      })

    Logger.info("Sending registration message to relay")

    {:reply, {:text, registration_msg}, state}
  end

  def handle_info(:heartbeat, state) do
    # Send heartbeat ping
    msg = Jason.encode!(%{type: "ping"})

    # Schedule next heartbeat
    if state.heartbeat_timer do
      Process.cancel_timer(state.heartbeat_timer)
    end

    timer = Process.send_after(self(), :heartbeat, @heartbeat_interval)
    state = %{state | heartbeat_timer: timer}

    {:reply, {:text, msg}, state}
  end

  @impl WebSockex
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, data} ->
        handle_relay_message(data, state)

      {:error, reason} ->
        Logger.warning("Failed to decode relay message: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl WebSockex
  def handle_frame({:ping, _}, state) do
    {:reply, :pong, state}
  end

  @impl WebSockex
  def handle_frame(_frame, state) do
    {:ok, state}
  end

  @impl WebSockex
  def handle_cast(:ping, state) do
    msg = Jason.encode!(%{type: "ping"})
    {:reply, {:text, msg}, state}
  end

  @impl WebSockex
  def handle_cast({:update_urls, direct_urls}, state) do
    # Update state with new URLs
    state = %{state | direct_urls: direct_urls}

    # Send URL update message to relay
    msg =
      Jason.encode!(%{
        type: "update_urls",
        direct_urls: direct_urls
      })

    {:reply, {:text, msg}, state}
  end

  @impl WebSockex
  def handle_cast(:reconnect, state) do
    Logger.info("Manual reconnection requested")
    {:close, state}
  end

  @impl WebSockex
  def handle_cast({:send_relay_message, session_id, payload}, state) do
    # Encode and send message back through the relay
    msg =
      Jason.encode!(%{
        type: "relay_message",
        session_id: session_id,
        payload: Base.encode64(payload)
      })

    {:reply, {:text, msg}, state}
  end

  @impl WebSockex
  def handle_cast({:create_claim, user_id, code, ttl_seconds}, state) do
    if state.registered do
      msg =
        Jason.encode!(%{
          type: "create_claim",
          user_id: user_id,
          code: code,
          ttl_seconds: ttl_seconds
        })

      Logger.info("Sending create_claim request to relay for code: #{code}")
      {:reply, {:text, msg}, state}
    else
      Logger.warning("Cannot create claim: not registered with relay")
      {:ok, state}
    end
  end

  @impl WebSockex
  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("Disconnected from relay service: #{inspect(reason)}")

    # Cancel heartbeat timer
    if state.heartbeat_timer do
      Process.cancel_timer(state.heartbeat_timer)
    end

    # Calculate reconnect delay with exponential backoff
    delay = min(state.reconnect_delay, @max_reconnect_delay)
    next_delay = min(state.reconnect_delay * 2, @max_reconnect_delay)

    Logger.info("Attempting to reconnect to relay in #{delay}ms...")

    # Update state for next connection
    state = %{state | registered: false, heartbeat_timer: nil, reconnect_delay: next_delay}

    {:reconnect, delay, state}
  end

  @impl WebSockex
  def terminate(reason, state) do
    Logger.info("Relay connection terminated: #{inspect(reason)}")

    # Cancel heartbeat timer
    if state.heartbeat_timer do
      Process.cancel_timer(state.heartbeat_timer)
    end

    :ok
  end

  # Private Functions

  defp handle_relay_message(%{"type" => "registered"}, state) do
    Logger.info("Successfully registered with relay service")
    {:ok, %{state | registered: true}}
  end

  defp handle_relay_message(%{"type" => "pong"}, state) do
    # Heartbeat acknowledged
    {:ok, state}
  end

  defp handle_relay_message(
         %{
           "type" => "connection",
           "session_id" => session_id
         } = msg,
         state
       ) do
    Logger.info("Received relayed connection request: session_id=#{session_id}")

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
    # The tunnel will handle the Noise handshake and forward messages to DeviceChannel
    Logger.info("Accepting relayed connection from client (session: #{session_id})")

    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      "relay:connections",
      {:relay_connection, session_id, client_public_key, self()}
    )

    {:ok, state}
  end

  defp handle_relay_message(
         %{"type" => "relay_message", "session_id" => session_id, "payload" => payload_b64},
         state
       ) do
    # Forward relayed message to the appropriate session
    case Base.decode64(payload_b64) do
      {:ok, payload} ->
        Logger.debug("Forwarding relay message for session #{session_id}")

        # Broadcast to the specific session's tunnel
        Phoenix.PubSub.broadcast(
          Mydia.PubSub,
          "relay:session:#{session_id}",
          {:relay_message, payload}
        )

        {:ok, state}

      :error ->
        Logger.warning("Invalid payload in relay message")
        {:ok, state}
    end
  end

  defp handle_relay_message(%{"type" => "error", "message" => error_msg}, state) do
    Logger.error("Relay service error: #{error_msg}")
    {:ok, state}
  end

  defp handle_relay_message(
         %{"type" => "claim_created", "code" => code, "expires_at" => expires_at},
         state
       ) do
    Logger.info("Claim registered with relay: #{code}")

    # Broadcast to anyone waiting for this claim confirmation
    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      "relay:claim:#{code}",
      {:claim_created, code, expires_at}
    )

    {:ok, state}
  end

  defp handle_relay_message(msg, state) do
    Logger.debug("Unhandled relay message: #{inspect(msg)}")
    {:ok, state}
  end

  defp get_relay_config do
    case RemoteAccess.get_config() do
      nil ->
        {:error, :not_configured}

      config ->
        if config.enabled do
          {:ok, config}
        else
          {:error, :disabled}
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
