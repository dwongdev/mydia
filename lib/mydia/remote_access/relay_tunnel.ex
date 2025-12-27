defmodule Mydia.RemoteAccess.RelayTunnel do
  @moduledoc """
  Handles relay-tunneled connections from clients.

  This module subscribes to relay connection events and creates a bridge
  between the relay WebSocket and the DeviceChannel, allowing clients to
  connect through the relay when direct connections fail.

  ## Architecture

  ```
  Client <-> Relay <-> RelayTunnel <-> DeviceChannel
  ```

  The tunnel:
  1. Subscribes to relay:connections PubSub topic
  2. Receives incoming connection events with session_id and client public key
  3. Creates a process to handle the tunneled connection
  4. Forwards messages bidirectionally between relay and DeviceChannel
  """

  use GenServer
  require Logger

  alias Mydia.RemoteAccess.Relay
  alias Mydia.RemoteAccess.Pairing

  # Client API

  @doc """
  Starts the relay tunnel supervisor.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    # Subscribe to relay connection events
    Phoenix.PubSub.subscribe(Mydia.PubSub, "relay:connections")
    Logger.info("RelayTunnel supervisor started and subscribed to relay connections")
    {:ok, %{tunnels: %{}}}
  end

  @impl true
  def handle_info({:relay_connection, session_id, client_public_key, relay_pid}, state) do
    Logger.info("Received relay connection request: session_id=#{session_id}")

    # Start a tunnel process for this connection
    {:ok, tunnel_pid} =
      Task.start_link(fn ->
        handle_tunnel(session_id, client_public_key, relay_pid)
      end)

    tunnels = Map.put(state.tunnels, session_id, tunnel_pid)
    {:noreply, %{state | tunnels: tunnels}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private Functions

  defp handle_tunnel(session_id, _client_public_key, relay_pid) do
    Logger.info("Starting tunnel handler for session: #{session_id}")

    # Subscribe to messages for this specific session
    Phoenix.PubSub.subscribe(Mydia.PubSub, "relay:session:#{session_id}")

    # Initialize pairing handshake (assuming NK pattern for relay connections)
    case Pairing.start_pairing_handshake() do
      {:ok, handshake_state} ->
        # Run the tunnel message loop
        tunnel_loop(session_id, relay_pid, handshake_state)

      {:error, reason} ->
        Logger.error("Failed to initialize handshake for relay tunnel: #{inspect(reason)}")
        send_error_to_client(session_id, relay_pid, "handshake_init_failed")
    end
  end

  defp tunnel_loop(session_id, relay_pid, handshake_state) do
    receive do
      {:relay_message, payload} ->
        # Decode message from client via relay
        case decode_tunnel_message(payload) do
          {:ok, message_type, data} ->
            # Process the message
            case handle_tunnel_message(message_type, data, handshake_state) do
              {:ok, response, new_state} ->
                # Send response back through relay
                send_to_relay(session_id, relay_pid, response)
                tunnel_loop(session_id, relay_pid, new_state)

              {:error, reason} ->
                Logger.error("Tunnel message processing failed: #{inspect(reason)}")
                send_error_to_client(session_id, relay_pid, "message_processing_failed")
                tunnel_loop(session_id, relay_pid, handshake_state)

              :close ->
                Logger.info("Closing tunnel session: #{session_id}")
                :ok
            end

          {:error, reason} ->
            Logger.warning("Failed to decode tunnel message: #{inspect(reason)}")
            tunnel_loop(session_id, relay_pid, handshake_state)
        end

      {:DOWN, _ref, :process, ^relay_pid, reason} ->
        Logger.info("Relay connection closed for session #{session_id}: #{inspect(reason)}")
        :ok
    after
      # 5 minute timeout for tunnel inactivity
      300_000 ->
        Logger.info("Tunnel session timeout: #{session_id}")
        :ok
    end
  end

  defp decode_tunnel_message(payload) do
    case Jason.decode(payload) do
      {:ok, %{"type" => type, "data" => data}} ->
        {:ok, type, data}

      {:ok, %{"type" => type}} ->
        {:ok, type, %{}}

      {:error, reason} ->
        {:error, {:json_decode_failed, reason}}
    end
  end

  defp handle_tunnel_message("pairing_handshake", %{"message" => client_message_b64}, state) do
    case Base.decode64(client_message_b64) do
      {:ok, client_message} ->
        case Pairing.process_pairing_message(state, client_message) do
          {:ok, final_state, response_message} ->
            response = %{
              type: "pairing_handshake",
              message: Base.encode64(response_message)
            }

            {:ok, Jason.encode!(response), final_state}

          {:error, reason} ->
            {:error, {:handshake_failed, reason}}
        end

      :error ->
        {:error, :invalid_base64}
    end
  end

  defp handle_tunnel_message(
         "claim_code",
         %{"code" => code, "device_name" => device_name, "platform" => platform},
         state
       ) do
    unless Decibel.is_handshake_complete?(state) do
      {:error, :handshake_incomplete}
    else
      device_attrs = %{
        device_name: device_name,
        platform: platform
      }

      case Pairing.complete_pairing(code, device_attrs, state) do
        {:ok, device, media_token, {device_public_key, device_private_key}, final_state} ->
          # Publish device connected event
          Mydia.RemoteAccess.publish_device_event(device, :connected)

          response = %{
            type: "pairing_complete",
            device_id: device.id,
            media_token: media_token,
            device_public_key: Base.encode64(device_public_key),
            device_private_key: Base.encode64(device_private_key)
          }

          {:ok, Jason.encode!(response), final_state}

        {:error, reason} ->
          {:error, {:pairing_failed, reason}}
      end
    end
  end

  defp handle_tunnel_message("handshake_init", %{"message" => client_message_b64}, state) do
    case Base.decode64(client_message_b64) do
      {:ok, client_message} ->
        case Pairing.process_client_message(state, client_message) do
          {:ok, final_state, _client_static_key, response_message, device} ->
            case Pairing.complete_reconnection(device, final_state) do
              {:ok, updated_device, token, _final_state} ->
                # Publish device connected event
                Mydia.RemoteAccess.publish_device_event(updated_device, :connected)

                response = %{
                  type: "handshake_complete",
                  message: Base.encode64(response_message),
                  token: token,
                  device_id: updated_device.id
                }

                {:ok, Jason.encode!(response), final_state}

              {:error, reason} ->
                {:error, {:reconnection_failed, reason}}
            end

          {:error, reason} ->
            {:error, {:handshake_failed, reason}}
        end

      :error ->
        {:error, :invalid_base64}
    end
  end

  defp handle_tunnel_message("close", _data, _state) do
    :close
  end

  defp handle_tunnel_message(type, _data, state) do
    Logger.debug("Unknown tunnel message type: #{type}")
    {:ok, Jason.encode!(%{type: "error", message: "unknown_message_type"}), state}
  end

  defp send_to_relay(session_id, relay_pid, response) when is_binary(response) do
    Relay.send_relay_message(relay_pid, session_id, response)
  end

  defp send_error_to_client(session_id, relay_pid, error_message) do
    response = Jason.encode!(%{type: "error", message: error_message})
    send_to_relay(session_id, relay_pid, response)
  end
end
