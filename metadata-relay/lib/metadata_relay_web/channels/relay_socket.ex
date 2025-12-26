defmodule MetadataRelayWeb.RelaySocket do
  @moduledoc """
  WebSocket socket for relay tunnel connections.

  This socket handles persistent connections from Mydia instances
  for the remote access relay functionality:

  1. Instance connects via WebSocket
  2. Instance sends registration message with ID and public key
  3. Socket authenticates and maintains connection
  4. Socket forwards messages between clients and instance

  ## Protocol

  All messages are JSON-encoded:

  - Registration: `{"type": "register", "instance_id": "...", "public_key": "base64", "direct_urls": [...]}`
  - Heartbeat: `{"type": "ping"}` / `{"type": "pong"}`
  - URL Update: `{"type": "update_urls", "direct_urls": [...]}`
  - Relay Message: `{"type": "relay_message", "session_id": "...", "payload": "base64"}`
  """

  @behaviour Phoenix.Socket.Transport
  require Logger

  alias MetadataRelay.Relay

  # Heartbeat timeout: 60 seconds (should receive ping every 30 seconds)
  @heartbeat_timeout 60_000

  @impl true
  def child_spec(_opts) do
    # No child process needed per socket
    %{id: __MODULE__, start: {Task, :start_link, [fn -> :ok end]}, restart: :transient}
  end

  @impl true
  def connect(_state) do
    # Start unregistered - instance must send register message first
    {:ok,
     %{
       instance_id: nil,
       instance: nil,
       registered: false,
       heartbeat_timer: nil
     }}
  end

  @impl true
  def init(state) do
    # Start heartbeat timeout timer
    timer = Process.send_after(self(), :heartbeat_timeout, @heartbeat_timeout)
    {:ok, %{state | heartbeat_timer: timer}}
  end

  @impl true
  def handle_in({text, _opts}, state) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, message} ->
        handle_message(message, state)

      {:error, _reason} ->
        Logger.warning("Invalid JSON received from relay socket")
        {:ok, state}
    end
  end

  @impl true
  def handle_info(:heartbeat_timeout, state) do
    Logger.warning("Heartbeat timeout for instance: #{state.instance_id || "unregistered"}")
    {:stop, :heartbeat_timeout, state}
  end

  @impl true
  def handle_info({:relay_connection, session_id, client_public_key}, state) do
    # Forward incoming connection request to the instance
    message =
      Jason.encode!(%{
        type: "connection",
        session_id: session_id,
        client_public_key: Base.encode64(client_public_key)
      })

    {:push, {:text, message}, state}
  end

  @impl true
  def handle_info({:relay_message, session_id, payload}, state) do
    # Forward relayed message to the instance
    message =
      Jason.encode!(%{
        type: "relay_message",
        session_id: session_id,
        payload: Base.encode64(payload)
      })

    {:push, {:text, message}, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Relay socket terminated: #{inspect(reason)}, instance: #{state.instance_id}")

    # Mark instance as offline
    if state.instance_id do
      Relay.set_offline_by_instance_id(state.instance_id)
    end

    # Cancel heartbeat timer
    if state.heartbeat_timer do
      Process.cancel_timer(state.heartbeat_timer)
    end

    :ok
  end

  # Message handlers

  defp handle_message(%{"type" => "register"} = msg, state) do
    instance_id = msg["instance_id"]
    public_key_b64 = msg["public_key"]
    direct_urls = msg["direct_urls"] || []

    with {:ok, public_key} <- Base.decode64(public_key_b64),
         true <- byte_size(public_key) == 32,
         {:ok, instance} <-
           Relay.register_instance(%{
             instance_id: instance_id,
             public_key: public_key,
             direct_urls: direct_urls
           }),
         {:ok, instance} <- Relay.set_online(instance) do
      Logger.info("Instance registered: #{instance_id}")

      # Subscribe to relay messages for this instance
      Phoenix.PubSub.subscribe(MetadataRelay.PubSub, "relay:instance:#{instance_id}")

      # Reset heartbeat timer
      state = reset_heartbeat_timer(state)

      # Send registration confirmation
      response = Jason.encode!(%{type: "registered"})

      {:reply, :ok, {:text, response},
       %{state | instance_id: instance_id, instance: instance, registered: true}}
    else
      _ ->
        Logger.warning("Failed to register instance: #{instance_id}")
        error = Jason.encode!(%{type: "error", message: "Registration failed"})
        {:reply, :error, {:text, error}, state}
    end
  end

  defp handle_message(%{"type" => "ping"}, state) do
    state = reset_heartbeat_timer(state)
    response = Jason.encode!(%{type: "pong"})
    {:reply, :ok, {:text, response}, state}
  end

  defp handle_message(%{"type" => "pong"}, state) do
    # Response to our ping - just reset timer
    {:ok, reset_heartbeat_timer(state)}
  end

  defp handle_message(%{"type" => "update_urls", "direct_urls" => urls}, state)
       when is_list(urls) do
    if state.registered and state.instance do
      case Relay.update_heartbeat(state.instance, %{direct_urls: urls}) do
        {:ok, instance} ->
          {:ok, %{state | instance: instance}}

        _ ->
          {:ok, state}
      end
    else
      {:ok, state}
    end
  end

  defp handle_message(
         %{"type" => "relay_message", "session_id" => session_id, "payload" => payload_b64},
         state
       ) do
    # Forward response from instance to client via PubSub
    case Base.decode64(payload_b64) do
      {:ok, payload} ->
        Phoenix.PubSub.broadcast(
          MetadataRelay.PubSub,
          "relay:session:#{session_id}",
          {:relay_response, payload}
        )

        {:ok, state}

      :error ->
        Logger.warning("Invalid base64 payload in relay message")
        {:ok, state}
    end
  end

  defp handle_message(msg, state) do
    Logger.debug("Unhandled relay message: #{inspect(msg)}")
    {:ok, state}
  end

  defp reset_heartbeat_timer(state) do
    if state.heartbeat_timer do
      Process.cancel_timer(state.heartbeat_timer)
    end

    timer = Process.send_after(self(), :heartbeat_timeout, @heartbeat_timeout)
    %{state | heartbeat_timer: timer}
  end
end
