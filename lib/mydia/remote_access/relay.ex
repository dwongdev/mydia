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
        url = config.relay_url
        instance_id = config.instance_id
        public_key = config.static_public_key

        # Convert ws:// or wss:// URL format if needed
        url = normalize_relay_url(url)

        state = %{
          instance_id: instance_id,
          public_key: public_key,
          relay_url: url,
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
  """
  def status(pid \\ __MODULE__) do
    try do
      state = :sys.get_state(pid)
      {:ok, %{connected: true, registered: state.registered, instance_id: state.instance_id}}
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
    WebSockex.cast(pid, :ping)
  end

  # WebSockex Callbacks

  @impl WebSockex
  def handle_connect(_conn, state) do
    Logger.info("Connected to relay service at #{state.relay_url}")

    # Send registration message
    registration_msg =
      Jason.encode!(%{
        type: "register",
        instance_id: state.instance_id,
        public_key: Base.encode64(state.public_key)
      })

    # Schedule first heartbeat
    timer = Process.send_after(self(), :heartbeat, @heartbeat_interval)

    # Reset reconnect delay on successful connection
    state = %{state | heartbeat_timer: timer, reconnect_delay: @initial_reconnect_delay}

    {:ok, state, {:text, registration_msg}}
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
         %{"type" => "connection", "session_id" => session_id, "client_public_key" => client_key},
         state
       ) do
    Logger.info("Received relayed connection request: session_id=#{session_id}")

    # Decode client public key
    case Base.decode64(client_key) do
      {:ok, client_public_key} ->
        # TODO: Handle incoming relayed connection
        # This will be implemented in a later task to integrate with the Noise handshake
        Logger.info(
          "Accepting relayed connection from client (session: #{session_id}, key: #{byte_size(client_public_key)} bytes)"
        )

        {:ok, state}

      :error ->
        Logger.warning("Invalid client public key in connection request")
        {:ok, state}
    end
  end

  defp handle_relay_message(%{"type" => "error", "message" => error_msg}, state) do
    Logger.error("Relay service error: #{error_msg}")
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
    # Convert http:// to ws:// and https:// to wss://
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
  end
end
