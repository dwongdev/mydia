defmodule Mydia.RemoteAccess.Pairing do
  @moduledoc """
  Handles X25519 key exchange for device pairing and reconnection.

  ## Simplified Key Exchange

  This module uses a simplified X25519 key exchange instead of the full Noise Protocol.
  Both parties exchange public keys and derive a shared session key using HKDF.

  ## Pairing Flow

  1. Client generates X25519 keypair
  2. Client sends base64-encoded public key to server
  3. Server generates its own X25519 keypair
  4. Server derives session key: HKDF(ECDH(server_priv, client_pub))
  5. Server sends its public key back to client
  6. Client derives same session key: HKDF(ECDH(client_priv, server_pub))
  7. Both parties now have identical session keys for encryption

  ## Reconnection Flow (IK-style)

  1. Client sends its stored static public key
  2. Server verifies the key exists in the database
  3. Server responds with success/failure
  4. Session key derived from stored keys

  ## Security Notes

  - Uses X25519 (Curve25519) for ECDH key exchange
  - Uses HKDF-SHA256 for session key derivation
  - Uses ChaCha20-Poly1305 for authenticated encryption
  - Provides forward secrecy via ephemeral keys during pairing
  """

  require Logger

  alias Mydia.RemoteAccess
  alias Mydia.RemoteAccess.RemoteDevice
  alias Mydia.RemoteAccess.MediaToken
  alias Mydia.Crypto

  @doc """
  Initializes a reconnection handshake as the responder (server side).

  Generates a new server keypair for this session.

  Returns `{:ok, server_public_key, server_private_key}` on success.

  ## Examples

      iex> {:ok, public_key, private_key} = Mydia.RemoteAccess.Pairing.start_reconnect_handshake()
      iex> byte_size(public_key)
      32

  """
  @spec start_reconnect_handshake() ::
          {:ok, binary(), binary()} | {:error, :keypair_not_configured | :decryption_failed}
  def start_reconnect_handshake do
    # Generate a new ephemeral keypair for this session
    {public_key, private_key} = Crypto.generate_keypair()
    {:ok, public_key, private_key}
  end

  @doc """
  Processes the client's public key for reconnection.

  The client sends its static public key (base64 encoded or raw bytes).
  This function:
  1. Decodes the client's public key if needed
  2. Verifies it against the database
  3. Derives a session key using the server's private key

  ## Parameters

  - `server_private_key` - The server's ephemeral private key (32 bytes)
  - `client_public_key` - The client's static public key (32 bytes, base64 or raw)

  Returns `{:ok, session_key, device}` on success.
  Returns `{:error, reason}` on failure.
  """
  @spec process_client_message(binary(), binary()) ::
          {:ok, binary(), RemoteDevice.t()}
          | {:error, :device_not_found | :handshake_failed | :invalid_key}
  def process_client_message(server_private_key, client_public_key)
      when byte_size(server_private_key) == 32 do
    # Decode client public key if base64 encoded
    decoded_key =
      case byte_size(client_public_key) do
        32 -> client_public_key
        _ -> Base.decode64!(client_public_key)
      end

    # Verify the client's static key against the database
    case verify_device_key(decoded_key) do
      {:ok, device} ->
        # Derive session key using ECDH + HKDF
        session_key = Crypto.derive_session_key(server_private_key, decoded_key)
        {:ok, session_key, device}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _error ->
      {:error, :invalid_key}
  end

  @doc """
  Verifies a device's static public key against the database.

  Checks that:
  1. A device with this static key exists
  2. The device has not been revoked

  Returns `{:ok, device}` if valid, `{:error, reason}` otherwise.

  ## Examples

      iex> {public, _private} = Mydia.Crypto.generate_keypair()
      iex> Mydia.RemoteAccess.Pairing.verify_device_key(public)
      {:error, :device_not_found}

  """
  @spec verify_device_key(binary()) ::
          {:ok, RemoteDevice.t()} | {:error, :device_not_found}
  def verify_device_key(device_static_public_key) when is_binary(device_static_public_key) do
    case Mydia.Repo.get_by(RemoteDevice, device_static_public_key: device_static_public_key) do
      nil ->
        {:error, :device_not_found}

      device ->
        if RemoteDevice.revoked?(device) do
          # Return same error as not found to prevent device enumeration
          # An attacker should not be able to distinguish between
          # "device doesn't exist" and "device exists but is revoked"
          Logger.warning("Attempted reconnection with revoked device: #{device.id}")
          {:error, :device_not_found}
        else
          {:ok, device}
        end
    end
  end

  @doc """
  Completes the reconnection process after successful key exchange.

  This function:
  1. Updates the device's `last_seen_at` timestamp
  2. Generates a fresh media access token
  3. Returns the device, token, and session key for the client

  The session key can be used for subsequent encrypted communication
  via `Mydia.Crypto.encrypt/2` and `Mydia.Crypto.decrypt/4`.

  Returns `{:ok, device, token, session_key}` on success.
  """
  @spec complete_reconnection(RemoteDevice.t(), binary()) ::
          {:ok, RemoteDevice.t(), String.t(), binary()}
          | {:error, Ecto.Changeset.t()}
  def complete_reconnection(device, session_key) when byte_size(session_key) == 32 do
    # Update last_seen_at
    case RemoteAccess.touch_device(device) do
      {:ok, updated_device} ->
        # Generate a fresh media access token
        # For now, we'll use a simple token generation
        # In production, this should integrate with your token system
        token = generate_media_token(updated_device)

        {:ok, updated_device, token, session_key}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Generates a JWT media access token for the device
  defp generate_media_token(device) do
    case MediaToken.create_token(device) do
      {:ok, token, _claims} -> token
      {:error, _reason} -> raise "Failed to generate media token"
    end
  end

  # ============================================================================
  # X25519 Pairing Functions
  # ============================================================================

  @doc """
  Initializes a pairing handshake as the responder (server side) for initial device pairing.

  Generates a new server keypair for this pairing session.
  The server's public key should be sent to the client.

  Returns `{:ok, server_public_key, server_private_key}` on success.

  ## Examples

      iex> {:ok, public_key, private_key} = Mydia.RemoteAccess.Pairing.start_pairing_handshake()
      iex> byte_size(public_key)
      32

  """
  @spec start_pairing_handshake() ::
          {:ok, binary(), binary()}
  def start_pairing_handshake do
    # Generate a new ephemeral keypair for this pairing session
    {public_key, private_key} = Crypto.generate_keypair()
    {:ok, public_key, private_key}
  end

  @doc """
  Processes the client's public key for pairing.

  The client sends its ephemeral public key (base64 encoded or raw bytes).
  This function:
  1. Decodes the client's public key if needed
  2. Derives a session key using the server's private key

  ## Parameters

  - `server_private_key` - The server's ephemeral private key (32 bytes)
  - `client_public_key` - The client's public key (32 bytes, base64 or raw)

  Returns `{:ok, session_key}` on success.
  Returns `{:error, :invalid_key}` on failure.
  """
  @spec process_pairing_message(binary(), binary()) ::
          {:ok, binary()} | {:error, :invalid_key}
  def process_pairing_message(server_private_key, client_public_key)
      when byte_size(server_private_key) == 32 do
    # Decode client public key if base64 encoded
    decoded_key =
      case byte_size(client_public_key) do
        32 -> client_public_key
        _ -> Base.decode64!(client_public_key)
      end

    # Derive session key using ECDH + HKDF
    session_key = Crypto.derive_session_key(server_private_key, decoded_key)
    {:ok, session_key}
  rescue
    _error ->
      {:error, :invalid_key}
  end

  @doc """
  Completes the pairing process after successful key exchange and claim code validation.

  This function:
  1. Validates the claim code
  2. Registers the device with the client-provided public key
  3. Generates a fresh media access token
  4. Consumes the claim code

  The client generates its own X25519 keypair and sends only the public key.
  The private key never leaves the client device.

  Returns `{:ok, device, token, session_key}` on success.
  Returns `{:error, reason}` if claim code validation or device creation fails.

  ## Parameters

  - `claim_code` - The claim code entered by the user
  - `device_attrs` - Map containing device information (device_name, platform)
  - `client_static_public_key` - The client's static public key (32 bytes)
  - `session_key` - The derived session key (32 bytes)

  """
  @spec complete_pairing(String.t(), map(), binary(), binary()) ::
          {:ok, RemoteDevice.t(), String.t(), binary()}
          | {:error, :not_found | :already_used | :expired | :invalid_key | Ecto.Changeset.t()}
  def complete_pairing(claim_code, device_attrs, client_static_public_key, session_key)
      when byte_size(session_key) == 32 and byte_size(client_static_public_key) == 32 do
    # Validate the claim code
    with {:ok, claim} <- RemoteAccess.validate_claim_code(claim_code),
         # Generate a unique device token
         device_token = generate_device_token(),
         # Register the device with the client's public key
         device_params =
           Map.merge(device_attrs, %{
             device_static_public_key: client_static_public_key,
             token: device_token,
             user_id: claim.user_id
           }),
         {:ok, device} <- RemoteAccess.create_device(device_params),
         # Consume the claim code
         {:ok, _consumed_claim} <- RemoteAccess.consume_claim_code(claim_code, device.id) do
      # Generate media access token
      media_token = generate_media_token(device)

      # Return the device and media token (no keypair - client already has it)
      {:ok, device, media_token, session_key}
    end
  end

  def complete_pairing(_claim_code, _device_attrs, client_static_public_key, _session_key)
      when byte_size(client_static_public_key) != 32 do
    {:error, :invalid_key}
  end

  # Generates a unique device token
  # Used as a bearer token for API access
  defp generate_device_token do
    :crypto.strong_rand_bytes(32) |> Base.encode64(padding: false)
  end
end
