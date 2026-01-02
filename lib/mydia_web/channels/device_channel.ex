defmodule MydiaWeb.DeviceChannel do
  @moduledoc """
  Phoenix Channel for device pairing and reconnection using X25519 key exchange.

  ## Device Pairing (device:pair)

  This topic handles initial device pairing using X25519 ECDH key exchange.
  The client and server exchange ephemeral public keys to establish a shared
  session key.

  ### Pairing Flow

  1. Client joins "device:pair" topic
  2. Server generates ephemeral keypair
  3. Client sends "pairing_handshake" with their public key
  4. Server derives session key and responds with its public key
  5. Client sends "claim_code" with code and device info
  6. Server validates claim code, creates device, sends keypair and token

  ### Pairing Messages

  - `pairing_handshake` - Client sends public key, server responds with its key
  - `claim_code` - Client submits claim code and device info
  - `pairing_complete` - Server sends device keypair and media token
  - `pairing_error` - Server reports pairing failure

  ## Device Reconnection (device:reconnect)

  This topic handles the secure reconnection of paired devices using X25519
  key exchange. The device is authenticated by verifying its stored static
  public key against the database.

  ### Reconnection Flow

  1. Client joins "device:reconnect" topic
  2. Server generates ephemeral keypair
  3. Client sends "key_exchange" with their static public key and device token
  4. Server verifies device, derives session key, sends response
  5. On success, client receives fresh media token and server's public key

  ### Reconnection Messages

  - `key_exchange` - Client sends static public key and device token
  - `key_exchange_complete` - Server confirms and sends token + its public key
  - `key_exchange_error` - Server reports failure
  """
  use MydiaWeb, :channel

  alias Mydia.RemoteAccess.Pairing

  require Logger

  @impl true
  def join("device:pair", _payload, socket) do
    # Initialize the X25519 keypair for pairing when client joins
    case Pairing.start_pairing_handshake() do
      {:ok, server_public_key, server_private_key} ->
        # Store server keypair in socket assigns
        socket =
          socket
          |> assign(:server_public_key, server_public_key)
          |> assign(:server_private_key, server_private_key)
          |> assign(:handshake_complete, false)

        {:ok, socket}
    end
  end

  @impl true
  def join("device:reconnect", _payload, socket) do
    # Initialize the X25519 keypair for reconnection when client joins
    case Pairing.start_reconnect_handshake() do
      {:ok, server_public_key, server_private_key} ->
        # Store server keypair in socket assigns
        socket =
          socket
          |> assign(:server_public_key, server_public_key)
          |> assign(:server_private_key, server_private_key)

        {:ok, socket}
    end
  end

  @impl true
  def join(_topic, _payload, _socket) do
    {:error, %{reason: "invalid_topic"}}
  end

  # ============================================================================
  # Pairing Handlers (X25519 Key Exchange)
  # ============================================================================

  @impl true
  def handle_in("pairing_handshake", %{"message" => client_public_key_b64}, socket) do
    server_private_key = socket.assigns.server_private_key
    server_public_key = socket.assigns.server_public_key

    # Process client's public key and derive session key
    case Pairing.process_pairing_message(server_private_key, client_public_key_b64) do
      {:ok, session_key} ->
        # Update socket with session key and mark handshake as complete
        socket =
          socket
          |> assign(:session_key, session_key)
          |> assign(:handshake_complete, true)

        # Send server's public key back to client
        {:reply, {:ok, %{message: Base.encode64(server_public_key)}}, socket}

      {:error, :invalid_key} ->
        Logger.warning("Invalid public key received for pairing")
        {:reply, {:error, %{reason: "invalid_message"}}, socket}
    end
  end

  @impl true
  def handle_in(
        "claim_code",
        %{
          "code" => claim_code,
          "device_name" => device_name,
          "platform" => platform,
          "static_public_key" => static_public_key_b64
        },
        socket
      ) do
    # Verify handshake is complete
    unless socket.assigns[:handshake_complete] do
      Logger.warning("Claim code submitted before handshake completion")
      {:reply, {:error, %{reason: "handshake_incomplete"}}, socket}
    else
      # Decode client's static public key
      case Base.decode64(static_public_key_b64) do
        {:ok, client_static_public_key} ->
          session_key = socket.assigns.session_key

          device_attrs = %{
            device_name: device_name,
            platform: platform
          }

          # Complete the pairing process with client's public key
          case Pairing.complete_pairing(
                 claim_code,
                 device_attrs,
                 client_static_public_key,
                 session_key
               ) do
            {:ok, device, media_token, _session_key} ->
              # Update socket with device info
              socket =
                socket
                |> assign(:device_id, device.id)
                |> assign(:user_id, device.user_id)
                |> assign(:authenticated, true)

              # Publish device connected event
              Mydia.RemoteAccess.publish_device_event(device, :connected)

              # No keypair in response - client already has its own keys
              {:reply,
               {:ok,
                %{
                  device_id: device.id,
                  media_token: media_token
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

            {:error, :invalid_key} ->
              Logger.warning("Pairing failed: invalid public key")
              {:reply, {:error, %{reason: "invalid_public_key"}}, socket}

            {:error, %Ecto.Changeset{} = changeset} ->
              Logger.error("Pairing failed: device creation error: #{inspect(changeset)}")
              {:reply, {:error, %{reason: "device_creation_failed"}}, socket}

            {:error, reason} ->
              Logger.error("Unexpected error during pairing: #{inspect(reason)}")
              {:reply, {:error, %{reason: "internal_error"}}, socket}
          end

        :error ->
          Logger.warning("Pairing failed: invalid base64 public key")
          {:reply, {:error, %{reason: "invalid_public_key"}}, socket}
      end
    end
  end

  # ============================================================================
  # Reconnection Handlers (X25519 Key Exchange)
  # ============================================================================

  @impl true
  def handle_in(
        "key_exchange",
        %{"client_public_key" => client_public_key_b64, "device_token" => device_token},
        socket
      ) do
    server_private_key = socket.assigns.server_private_key
    server_public_key = socket.assigns.server_public_key

    # Process client's static public key and verify device
    with {:ok, session_key, device} <-
           Pairing.process_client_message(server_private_key, client_public_key_b64),
         true <- verify_device_token(device, device_token),
         {:ok, updated_device, token, _session_key} <-
           Pairing.complete_reconnection(device, session_key) do
      # Update socket with authenticated device info
      socket =
        socket
        |> assign(:device_id, updated_device.id)
        |> assign(:user_id, updated_device.user_id)
        |> assign(:session_key, session_key)
        |> assign(:authenticated, true)

      # Publish device connected event
      Mydia.RemoteAccess.publish_device_event(updated_device, :connected)

      # Send success response with server's public key and token
      {:reply,
       {:ok,
        %{
          server_public_key: Base.encode64(server_public_key),
          token: token,
          device_id: updated_device.id
        }}, socket}
    else
      false ->
        Logger.warning("Device reconnection failed: invalid device token")
        {:reply, {:error, %{reason: "invalid_device_token"}}, socket}

      {:error, :device_not_found} ->
        Logger.warning("Device reconnection failed: device not found")
        {:reply, {:error, %{reason: "device_not_found"}}, socket}

      {:error, :device_revoked} ->
        Logger.warning("Device reconnection failed: device revoked")
        {:reply, {:error, %{reason: "device_revoked"}}, socket}

      {:error, :invalid_key} ->
        Logger.warning("Invalid public key received for reconnection")
        {:reply, {:error, %{reason: "invalid_message"}}, socket}

      {:error, reason} ->
        Logger.error("Unexpected error during reconnection: #{inspect(reason)}")
        {:reply, {:error, %{reason: "internal_error"}}, socket}
    end
  end

  # Legacy handler for old Noise-based handshake_init (for backwards compatibility)
  @impl true
  def handle_in("handshake_init", %{"message" => _client_message_b64}, socket) do
    # This handler is kept for backwards compatibility but returns an error
    # directing clients to use the new key_exchange message
    Logger.warning("Deprecated handshake_init message received, use key_exchange instead")
    {:reply, {:error, %{reason: "use_key_exchange"}}, socket}
  end

  @impl true
  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "unknown_event"}}, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    # Publish disconnected event if device was authenticated
    if socket.assigns[:authenticated] && socket.assigns[:device_id] do
      case Mydia.RemoteAccess.get_device(socket.assigns.device_id) do
        nil ->
          :ok

        device ->
          Mydia.RemoteAccess.publish_device_event(device, :disconnected)
      end
    end

    :ok
  end

  # Private helper to verify device token against stored hash
  defp verify_device_token(device, provided_token) do
    # Verify the provided token against the stored Argon2 hash
    # Argon2.verify_pass is timing-safe
    case device.token_hash do
      nil -> false
      hash -> Argon2.verify_pass(provided_token, hash)
    end
  end
end
