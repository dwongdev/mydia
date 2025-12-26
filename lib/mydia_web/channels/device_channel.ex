defmodule MydiaWeb.DeviceChannel do
  @moduledoc """
  Phoenix Channel for device pairing and reconnection using Noise protocol.

  ## Device Pairing (device:pair)

  This topic handles initial device pairing using the Noise_NK protocol pattern.
  The client does not yet have a static key, so the server authenticates but
  the client does not (initially).

  ### Pairing Flow

  1. Client joins "device:pair" topic
  2. Server initializes NK handshake
  3. Client sends "pairing_handshake" with first handshake message
  4. Server responds with handshake completion
  5. Client sends "claim_code" with code and device info
  6. Server validates claim code, creates device, sends keypair and token
  7. Channel transitions to encrypted communication mode

  ### Pairing Messages

  - `pairing_handshake` - Client initiates NK handshake
  - `claim_code` - Client submits claim code and device info
  - `pairing_complete` - Server sends device keypair and media token
  - `pairing_error` - Server reports pairing failure

  ## Device Reconnection (device:reconnect)

  This topic handles the secure reconnection of paired devices using the
  Noise_IK protocol pattern, which provides mutual authentication.

  ### Reconnection Flow

  1. Client joins "device:reconnect" topic
  2. Client sends "handshake_init" with their first handshake message
  3. Server processes message, verifies device key, sends response
  4. On success, client receives fresh media token
  5. Channel transitions to encrypted communication mode

  ### Reconnection Messages

  - `handshake_init` - Client initiates handshake with first message
  - `handshake_complete` - Server confirms successful handshake and sends token
  - `handshake_error` - Server reports handshake failure
  """
  use MydiaWeb, :channel

  alias Mydia.RemoteAccess.Pairing

  require Logger

  @impl true
  def join("device:pair", _payload, socket) do
    # Initialize the NK handshake state for pairing when client joins
    case Pairing.start_pairing_handshake() do
      {:ok, handshake_state} ->
        # Store handshake state in socket assigns
        socket = assign(socket, :handshake_state, handshake_state)
        {:ok, socket}

      {:error, reason} ->
        Logger.error("Failed to initialize pairing handshake: #{inspect(reason)}")
        {:error, %{reason: "handshake_init_failed"}}
    end
  end

  @impl true
  def join("device:reconnect", _payload, socket) do
    # Initialize the IK handshake state for reconnection when client joins
    case Pairing.start_reconnect_handshake() do
      {:ok, handshake_state} ->
        # Store handshake state in socket assigns
        socket = assign(socket, :handshake_state, handshake_state)
        {:ok, socket}

      {:error, reason} ->
        Logger.error("Failed to initialize reconnect handshake: #{inspect(reason)}")
        {:error, %{reason: "handshake_init_failed"}}
    end
  end

  @impl true
  def join(_topic, _payload, _socket) do
    {:error, %{reason: "invalid_topic"}}
  end

  # ============================================================================
  # Pairing Handlers (Noise_NK)
  # ============================================================================

  @impl true
  def handle_in("pairing_handshake", %{"message" => client_message_b64}, socket) do
    # Decode the base64-encoded client message
    client_message_result =
      case Base.decode64(client_message_b64) do
        {:ok, msg} -> {:ok, msg}
        :error -> {:error, :invalid_base64}
      end

    with {:ok, client_message} <- client_message_result,
         handshake_state <- socket.assigns.handshake_state,
         {:ok, final_state, response_message} <-
           Pairing.process_pairing_message(handshake_state, client_message) do
      # Update socket with completed handshake state
      socket = assign(socket, :handshake_state, final_state)

      # Send success response with server's handshake message
      {:reply, {:ok, %{message: Base.encode64(response_message)}}, socket}
    else
      {:error, :handshake_failed} ->
        Logger.error("Noise NK pairing handshake failed")
        {:reply, {:error, %{reason: "handshake_failed"}}, socket}

      {:error, :invalid_base64} ->
        Logger.warning("Invalid base64 message received for pairing")
        {:reply, {:error, %{reason: "invalid_message"}}, socket}

      {:error, reason} ->
        Logger.error("Unexpected error during pairing handshake: #{inspect(reason)}")
        {:reply, {:error, %{reason: "internal_error"}}, socket}
    end
  end

  @impl true
  def handle_in(
        "claim_code",
        %{"code" => claim_code, "device_name" => device_name, "platform" => platform},
        socket
      ) do
    handshake_state = socket.assigns.handshake_state

    # Verify handshake is complete
    unless Decibel.is_handshake_complete?(handshake_state) do
      Logger.warning("Claim code submitted before handshake completion")
      {:reply, {:error, %{reason: "handshake_incomplete"}}, socket}
    else
      device_attrs = %{
        device_name: device_name,
        platform: platform
      }

      # Complete the pairing process
      case Pairing.complete_pairing(claim_code, device_attrs, handshake_state) do
        {:ok, device, media_token, {device_public_key, device_private_key}, final_state} ->
          # Update socket with device info
          socket =
            socket
            |> assign(:device_id, device.id)
            |> assign(:user_id, device.user_id)
            |> assign(:authenticated, true)
            |> assign(:handshake_state, final_state)

          # Send the device keypair and tokens to the client
          # The keypair is sent over the encrypted Noise channel
          {:reply,
           {:ok,
            %{
              device_id: device.id,
              media_token: media_token,
              device_public_key: Base.encode64(device_public_key),
              device_private_key: Base.encode64(device_private_key)
            }}, socket}

        {:error, :not_found} ->
          Logger.warning("Pairing failed: claim code not found")
          {:reply, {:error, %{reason: "invalid_claim_code"}}, socket}

        {:error, :already_used} ->
          Logger.warning("Pairing failed: claim code already used")
          {:reply, {:error, %{reason: "claim_code_used"}}, socket}

        {:error, :expired} ->
          Logger.warning("Pairing failed: claim code expired")
          {:reply, {:error, %{reason: "claim_code_expired"}}, socket}

        {:error, %Ecto.Changeset{} = changeset} ->
          Logger.error("Pairing failed: device creation error: #{inspect(changeset)}")
          {:reply, {:error, %{reason: "device_creation_failed"}}, socket}

        {:error, reason} ->
          Logger.error("Unexpected error during pairing: #{inspect(reason)}")
          {:reply, {:error, %{reason: "internal_error"}}, socket}
      end
    end
  end

  # ============================================================================
  # Reconnection Handlers (Noise_IK)
  # ============================================================================

  @impl true
  def handle_in("handshake_init", %{"message" => client_message_b64}, socket) do
    # Decode the base64-encoded client message
    # Note: Base.decode64 returns :error (not {:error, _}) on failure
    client_message_result =
      case Base.decode64(client_message_b64) do
        {:ok, msg} -> {:ok, msg}
        :error -> {:error, :invalid_base64}
      end

    with {:ok, client_message} <- client_message_result,
         handshake_state <- socket.assigns.handshake_state,
         {:ok, final_state, client_static_key, response_message, device} <-
           Pairing.process_client_message(handshake_state, client_message),
         {:ok, updated_device, token, _final_state} <-
           Pairing.complete_reconnection(device, final_state) do
      # Update socket with authenticated device info
      socket =
        socket
        |> assign(:device_id, updated_device.id)
        |> assign(:user_id, updated_device.user_id)
        |> assign(:client_static_key, client_static_key)
        |> assign(:authenticated, true)
        |> assign(:handshake_state, final_state)

      # Send success response with server's handshake message and token
      {:reply,
       {:ok,
        %{
          message: Base.encode64(response_message),
          token: token,
          device_id: updated_device.id
        }}, socket}
    else
      {:error, :device_not_found} ->
        Logger.warning("Device reconnection failed: device not found")
        {:reply, {:error, %{reason: "device_not_found"}}, socket}

      {:error, :device_revoked} ->
        Logger.warning("Device reconnection failed: device revoked")
        {:reply, {:error, %{reason: "device_revoked"}}, socket}

      {:error, :handshake_failed} ->
        Logger.error("Noise handshake failed")
        {:reply, {:error, %{reason: "handshake_failed"}}, socket}

      {:error, :invalid_base64} ->
        Logger.warning("Invalid base64 message received")
        {:reply, {:error, %{reason: "invalid_message"}}, socket}

      {:error, reason} ->
        Logger.error("Unexpected error during handshake: #{inspect(reason)}")
        {:reply, {:error, %{reason: "internal_error"}}, socket}
    end
  end

  @impl true
  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "unknown_event"}}, socket}
  end
end
