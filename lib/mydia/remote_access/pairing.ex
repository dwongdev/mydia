defmodule Mydia.RemoteAccess.Pairing do
  @moduledoc """
  Handles Noise protocol handshakes for device pairing and reconnection.

  ## Noise_IK Pattern (Reconnection)

  - I = Static key transmitted by initiator (client sends its static key)
  - K = Static key known to initiator (server's public key known to client)
  - Both parties authenticate each other

  ## Noise_IK Handshake Flow

  1. Client sends: `e, es, s, ss` (ephemeral key, static key encrypted with DH)
  2. Server verifies client's static key against `device_static_public_key` in database
  3. Server responds: `e, ee, se` (ephemeral key, complete DH)
  4. Mutual authentication complete, secure channel established

  ## Noise_NK Pattern (Initial Pairing)

  - N = No static key from initiator (client has no static key yet)
  - K = Static key known to initiator (server's public key known to client)
  - Client encrypts to server's known public key
  - Server authenticates; client does not (initially)

  ## Noise_NK Handshake Flow

  1. Client has server's public key (from QR code or manual entry)
  2. Client sends: `e, es` (ephemeral key, DH with server static)
  3. Server responds: `e, ee` (ephemeral key, DH ephemeral-ephemeral)
  4. Channel established with forward secrecy
  5. Claim code validated over encrypted channel
  6. Device registered and media token issued

  ## Security Notes

  - Uses Curve25519 for key exchange (via Decibel/libsodium)
  - Uses ChaCha20-Poly1305 for encryption (AEAD)
  - Uses BLAKE2b for hashing
  - Provides forward secrecy via ephemeral keys
  - IK provides mutual authentication via static keys
  - NK provides server authentication and channel encryption for claim code exchange
  """

  alias Mydia.RemoteAccess
  alias Mydia.RemoteAccess.RemoteDevice

  @doc """
  Initializes a Noise_IK handshake as the responder (server side).

  Returns a tuple containing the Decibel handshake state and the first message
  to send to the initiator.

  ## Examples

      iex> {:ok, handshake_state} = Mydia.RemoteAccess.Pairing.start_reconnect_handshake()
      iex> is_reference(handshake_state)
      true

  """
  @spec start_reconnect_handshake() ::
          {:ok, reference()} | {:error, :keypair_not_configured | :decryption_failed}
  def start_reconnect_handshake do
    # Get the server's keypair
    case RemoteAccess.get_private_key() do
      {:error, reason} ->
        {:error, reason}

      {:ok, private_key} ->
        public_key = RemoteAccess.get_public_key()

        # Initialize Noise_IK handshake as responder
        # The responder needs their own keypair (s)
        # Format: %{s: {public_key, private_key}}
        server_keys = %{s: {public_key, private_key}}

        # Create the responder state
        # Protocol: IK pattern with Curve25519, ChaCha20-Poly1305, BLAKE2b
        protocol_name = "Noise_IK_25519_ChaChaPoly_BLAKE2b"

        # Decibel.new/4 returns a reference to the handshake state
        handshake_state = Decibel.new(protocol_name, :rsp, server_keys)

        {:ok, handshake_state}
    end
  end

  @doc """
  Processes the first message from the client (initiator) in the Noise_IK handshake.

  The client's first message contains:
  - e: Client's ephemeral public key
  - es: DH(e, rs) - Diffie-Hellman between client ephemeral and server static
  - s: Client's static public key (encrypted)
  - ss: DH(s, rs) - Diffie-Hellman between client static and server static

  This function:
  1. Processes the incoming message
  2. Extracts the client's static public key
  3. Verifies it against the database
  4. Generates the response message

  Returns `{:ok, handshake_state, client_static_key, response_message, device}` on success.
  Returns `{:error, reason}` on failure.
  """
  @spec process_client_message(reference(), binary()) ::
          {:ok, reference(), binary(), binary(), RemoteDevice.t()}
          | {:error, :device_not_found | :device_revoked | :handshake_failed}
  def process_client_message(handshake_state, client_message) do
    # Process the client's first message (-> e, es, s, ss)
    # The responder decrypts and extracts the client's static key
    try do
      # Decrypt the client's handshake message
      _payload = Decibel.handshake_decrypt(handshake_state, client_message)

      # Get the client's static key from the handshake state
      client_static_key = Decibel.get_remote_key(handshake_state)

      # Verify the client's static key against the database
      case verify_device_key(client_static_key) do
        {:ok, device} ->
          # Generate response message (<- e, ee, se)
          # This completes the handshake and establishes the secure channel
          response_message = Decibel.handshake_encrypt(handshake_state, <<>>)

          {:ok, handshake_state, client_static_key, IO.iodata_to_binary(response_message), device}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      _error ->
        {:error, :handshake_failed}
    end
  end

  @doc """
  Verifies a device's static public key against the database.

  Checks that:
  1. A device with this static key exists
  2. The device has not been revoked

  Returns `{:ok, device}` if valid, `{:error, reason}` otherwise.

  ## Examples

      iex> {public, _private} = Mydia.Crypto.Noise.generate_keypair()
      iex> Mydia.RemoteAccess.Pairing.verify_device_key(public)
      {:error, :device_not_found}

  """
  @spec verify_device_key(binary()) ::
          {:ok, RemoteDevice.t()} | {:error, :device_not_found | :device_revoked}
  def verify_device_key(device_static_public_key) when is_binary(device_static_public_key) do
    case Mydia.Repo.get_by(RemoteDevice, device_static_public_key: device_static_public_key) do
      nil ->
        {:error, :device_not_found}

      device ->
        if RemoteDevice.revoked?(device) do
          {:error, :device_revoked}
        else
          {:ok, device}
        end
    end
  end

  @doc """
  Completes the reconnection process after successful handshake.

  This function:
  1. Updates the device's `last_seen_at` timestamp
  2. Generates a fresh media access token
  3. Returns the device and token for the client

  The handshake_state can be used for subsequent encrypted communication
  via `Decibel.encrypt!/2` and `Decibel.decrypt!/2`.

  Returns `{:ok, device, token, handshake_state}` on success.
  """
  @spec complete_reconnection(RemoteDevice.t(), reference()) ::
          {:ok, RemoteDevice.t(), String.t(), reference()}
          | {:error, Ecto.Changeset.t()}
  def complete_reconnection(device, handshake_state) do
    # Update last_seen_at
    case RemoteAccess.touch_device(device) do
      {:ok, updated_device} ->
        # Generate a fresh media access token
        # For now, we'll use a simple token generation
        # In production, this should integrate with your token system
        token = generate_media_token(updated_device)

        {:ok, updated_device, token, handshake_state}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Generates a media access token for the device
  # This is a placeholder - you should integrate with your actual token system
  defp generate_media_token(device) do
    # Generate a secure random token
    # In production, this should be a JWT or similar with proper expiration
    token_data = %{
      device_id: device.id,
      user_id: device.user_id,
      issued_at: DateTime.utc_now() |> DateTime.to_unix()
    }

    # For now, we'll create a simple token
    # You should replace this with proper JWT generation
    Base.encode64(:erlang.term_to_binary(token_data))
  end

  # ============================================================================
  # Noise_NK Pairing Functions
  # ============================================================================

  @doc """
  Initializes a Noise_NK handshake as the responder (server side) for initial device pairing.

  The NK pattern is used when the client does not yet have a static key pair.
  The server authenticates to the client, but the client does not authenticate yet.
  After the handshake, the claim code is validated and a device registration occurs.

  Returns a tuple containing the Decibel handshake state.

  ## Examples

      iex> {:ok, handshake_state} = Mydia.RemoteAccess.Pairing.start_pairing_handshake()
      iex> is_reference(handshake_state)
      true

  """
  @spec start_pairing_handshake() ::
          {:ok, reference()} | {:error, :not_configured}
  def start_pairing_handshake do
    # Get the server's keypair
    case RemoteAccess.get_private_key() do
      {:error, reason} ->
        {:error, reason}

      {:ok, private_key} ->
        public_key = RemoteAccess.get_public_key()

        # Initialize Noise_NK handshake as responder
        # The responder needs their own keypair (s)
        # Format: %{s: {public_key, private_key}}
        server_keys = %{s: {public_key, private_key}}

        # Create the responder state
        # Protocol: NK pattern with Curve25519, ChaCha20-Poly1305, BLAKE2b
        protocol_name = "Noise_NK_25519_ChaChaPoly_BLAKE2b"

        # Decibel.new/4 returns a reference to the handshake state
        handshake_state = Decibel.new(protocol_name, :rsp, server_keys)

        {:ok, handshake_state}
    end
  end

  @doc """
  Processes the first message from the client (initiator) in the Noise_NK handshake.

  The client's first message contains:
  - e: Client's ephemeral public key
  - es: DH(e, rs) - Diffie-Hellman between client ephemeral and server static

  This function:
  1. Processes the incoming message
  2. Generates the response message with server's ephemeral key

  Returns `{:ok, handshake_state, response_message}` on success.
  Returns `{:error, :handshake_failed}` on failure.
  """
  @spec process_pairing_message(reference(), binary()) ::
          {:ok, reference(), binary()} | {:error, :handshake_failed}
  def process_pairing_message(handshake_state, client_message) do
    # Process the client's first message (-> e, es)
    try do
      # Decrypt the client's handshake message
      _payload = Decibel.handshake_decrypt(handshake_state, client_message)

      # Generate response message (<- e, ee)
      # This completes the handshake and establishes the secure channel
      response_message = Decibel.handshake_encrypt(handshake_state, <<>>)

      {:ok, handshake_state, IO.iodata_to_binary(response_message)}
    rescue
      _error ->
        {:error, :handshake_failed}
    end
  end

  @doc """
  Completes the pairing process after successful NK handshake and claim code validation.

  This function:
  1. Validates the claim code
  2. Generates a new device keypair for the client
  3. Registers the device with the user
  4. Generates a fresh media access token
  5. Consumes the claim code

  The handshake_state can be used for subsequent encrypted communication
  to send the device keypair back to the client.

  Returns `{:ok, device, token, client_keypair, handshake_state}` on success.
  Returns `{:error, reason}` if claim code validation or device creation fails.

  ## Parameters

  - `claim_code` - The claim code entered by the user
  - `device_attrs` - Map containing device information (device_name, platform)
  - `handshake_state` - The completed NK handshake state

  """
  @spec complete_pairing(String.t(), map(), reference()) ::
          {:ok, RemoteDevice.t(), String.t(), {binary(), binary()}, reference()}
          | {:error, :not_found | :already_used | :expired | Ecto.Changeset.t()}
  def complete_pairing(claim_code, device_attrs, handshake_state) do
    # Validate the claim code
    with {:ok, claim} <- RemoteAccess.validate_claim_code(claim_code),
         # Generate a new keypair for the device
         {device_public_key, device_private_key} = Mydia.Crypto.Noise.generate_keypair(),
         # Generate a unique device token
         device_token = generate_device_token(),
         # Register the device
         device_params =
           Map.merge(device_attrs, %{
             device_static_public_key: device_public_key,
             token: device_token,
             user_id: claim.user_id
           }),
         {:ok, device} <- RemoteAccess.create_device(device_params),
         # Consume the claim code
         {:ok, _consumed_claim} <- RemoteAccess.consume_claim_code(claim_code, device.id) do
      # Generate media access token
      media_token = generate_media_token(device)

      # Return the device, media token, and the device's new keypair
      # The keypair needs to be sent to the client over the encrypted channel
      {:ok, device, media_token, {device_public_key, device_private_key}, handshake_state}
    end
  end

  # Generates a unique device token
  # Used as a bearer token for API access
  defp generate_device_token do
    :crypto.strong_rand_bytes(32) |> Base.encode64(padding: false)
  end
end
