defmodule Mydia.RemoteAccess.WebRTC.NoiseSession do
  @moduledoc """
  Manages Noise Protocol encryption for WebRTC DataChannels.

  Uses the Noise_IK_25519_ChaChaPoly_SHA256 protocol:
  - IK pattern: Client knows server's static public key upfront
  - X25519: Elliptic curve Diffie-Hellman
  - ChaCha20-Poly1305: AEAD cipher
  - SHA256: Hash function

  ## Wire Format

  Transport messages use this framing:
  ```
  || version (1) || channel (1) || flags (1) || counter (8) || ciphertext ||
  ```

  Channel IDs:
  - 0x01: mydia-api (GraphQL/JSON requests)
  - 0x02: mydia-media (binary media chunks)

  ## Usage

  1. Create a new session as responder with server static keypair
  2. Process handshake messages until complete
  3. Use encrypt/decrypt for transport messages
  """

  require Logger

  @protocol_name "Noise_IK_25519_ChaChaPoly_SHA256"

  # Wire format constants
  @protocol_version 1
  @channel_api 0x01
  @channel_media 0x02
  @flags_none 0x00

  # Header sizes
  @header_size 11
  # MAC size for ChaCha20-Poly1305 (not used directly but documented)
  # @mac_size 16

  @type state :: :handshake | :transport
  @type channel :: :api | :media

  defstruct [
    :noise_ref,
    :session_id,
    :instance_id,
    :tx_counter,
    :rx_counter,
    :state
  ]

  @type t :: %__MODULE__{
          noise_ref: reference() | nil,
          session_id: String.t(),
          instance_id: String.t(),
          tx_counter: non_neg_integer(),
          rx_counter: non_neg_integer(),
          state: state()
        }

  @doc """
  Creates a new NoiseSession as the responder (server side).

  The server static keypair should be provided as a tuple {public_key, private_key}.
  The prologue binds the handshake to the session context.

  ## Parameters

  - `static_keypair` - Server's static keypair as `{public_key, private_key}` (32 bytes each)
  - `session_id` - The WebRTC session ID (UUID string)
  - `instance_id` - The Mydia instance ID (UUID string)

  ## Returns

  `{:ok, noise_session}` on success, `{:error, reason}` on failure.
  """
  @spec new_responder(
          {binary(), binary()},
          String.t(),
          String.t()
        ) :: {:ok, t()} | {:error, term()}
  def new_responder({public_key, private_key}, session_id, instance_id)
      when byte_size(public_key) == 32 and byte_size(private_key) == 32 do
    # Build prologue: session_id || instance_id || protocol_version
    prologue = build_prologue(session_id, instance_id)

    try do
      # Create Noise responder with server static keypair and prologue
      noise_ref =
        Decibel.new(
          @protocol_name,
          :rsp,
          %{s: {public_key, private_key}, prologue: prologue}
        )

      session = %__MODULE__{
        noise_ref: noise_ref,
        session_id: session_id,
        instance_id: instance_id,
        tx_counter: 0,
        rx_counter: 0,
        state: :handshake
      }

      {:ok, session}
    rescue
      e ->
        Logger.error("Failed to create Noise session: #{inspect(e)}")
        {:error, {:noise_init_failed, e}}
    end
  end

  @doc """
  Processes an incoming handshake message.

  For IK pattern as responder:
  - Message 1 (from client): e, es, s, ss
  - Message 2 (to client): e, ee, se

  ## Parameters

  - `session` - The NoiseSession struct
  - `ciphertext` - The encrypted handshake message

  ## Returns

  - `{:ok, session, nil}` - Handshake needs another message (expecting msg 1)
  - `{:ok, session, response}` - Handshake complete or needs response sent
  - `{:error, reason}` - Handshake failed
  """
  @spec process_handshake(t(), binary()) ::
          {:ok, t(), binary() | nil} | {:error, term()}
  def process_handshake(%__MODULE__{state: :handshake} = session, ciphertext) do
    try do
      # Decrypt incoming handshake message (message 1 from initiator)
      _payload = Decibel.handshake_decrypt(session.noise_ref, ciphertext)

      # Check if handshake is complete after this message
      if Decibel.is_handshake_complete?(session.noise_ref) do
        # IK pattern completes after 2 messages, but we need to send msg 2
        # This shouldn't happen for IK responder after msg 1
        session = %{session | state: :transport}
        {:ok, session, nil}
      else
        # Generate response (message 2: <- e, ee, se)
        response = Decibel.handshake_encrypt(session.noise_ref, <<>>)

        # After sending message 2, handshake should be complete
        if Decibel.is_handshake_complete?(session.noise_ref) do
          session = %{session | state: :transport}
          handshake_hash = Decibel.get_handshake_hash(session.noise_ref)

          Logger.info(
            "Noise handshake complete for session #{session.session_id}, " <>
              "hash=#{Base.encode16(handshake_hash, case: :lower)}"
          )

          {:ok, session, response}
        else
          # Handshake still in progress (shouldn't happen for IK)
          {:ok, session, response}
        end
      end
    rescue
      e in Decibel.DecryptionError ->
        Logger.warning("Noise handshake decryption failed: #{inspect(e)}")
        {:error, :handshake_decryption_failed}

      e ->
        Logger.error("Noise handshake failed: #{inspect(e)}")
        {:error, {:handshake_failed, e}}
    end
  end

  def process_handshake(%__MODULE__{state: :transport}, _ciphertext) do
    {:error, :handshake_already_complete}
  end

  @doc """
  Checks if the handshake is complete and transport mode is ready.
  """
  @spec handshake_complete?(t()) :: boolean()
  def handshake_complete?(%__MODULE__{state: :transport}), do: true
  def handshake_complete?(%__MODULE__{}), do: false

  @doc """
  Gets the handshake hash for channel binding.

  Only available after handshake completion.
  """
  @spec get_handshake_hash(t()) :: binary() | nil
  def get_handshake_hash(%__MODULE__{state: :transport, noise_ref: ref}) do
    Decibel.get_handshake_hash(ref)
  end

  def get_handshake_hash(%__MODULE__{}), do: nil

  @doc """
  Encrypts a transport message for the specified channel.

  ## Parameters

  - `session` - The NoiseSession struct (must be in transport state)
  - `channel` - The channel (`:api` or `:media`)
  - `plaintext` - The data to encrypt

  ## Returns

  `{:ok, session, ciphertext}` with the framed encrypted message,
  or `{:error, reason}` if encryption fails.
  """
  @spec encrypt(t(), channel(), binary()) ::
          {:ok, t(), binary()} | {:error, term()}
  def encrypt(%__MODULE__{state: :transport} = session, channel, plaintext) do
    channel_id = channel_to_id(channel)
    counter = session.tx_counter

    # Build header for associated data
    header = build_header(channel_id, counter)

    try do
      # Encrypt with AD (the header)
      ciphertext = Decibel.encrypt(session.noise_ref, plaintext, header)

      # Build full framed message: header || ciphertext
      framed = header <> IO.iodata_to_binary(ciphertext)

      # Increment counter
      session = %{session | tx_counter: counter + 1}

      {:ok, session, framed}
    rescue
      e ->
        Logger.error("Noise encryption failed: #{inspect(e)}")
        {:error, {:encryption_failed, e}}
    end
  end

  def encrypt(%__MODULE__{state: :handshake}, _channel, _plaintext) do
    {:error, :handshake_not_complete}
  end

  @doc """
  Decrypts a transport message.

  Validates the header, checks replay protection, and decrypts the payload.

  ## Parameters

  - `session` - The NoiseSession struct (must be in transport state)
  - `framed_ciphertext` - The full framed message (header || ciphertext)

  ## Returns

  `{:ok, session, channel, plaintext}` with the decrypted data and channel,
  or `{:error, reason}` if decryption fails.
  """
  @spec decrypt(t(), binary()) ::
          {:ok, t(), channel(), binary()} | {:error, term()}
  def decrypt(%__MODULE__{state: :transport} = session, framed_ciphertext) do
    case parse_header(framed_ciphertext) do
      {:ok, channel_id, counter, header, ciphertext} ->
        # Replay protection: reject if counter <= last seen
        if counter <= session.rx_counter and session.rx_counter > 0 do
          Logger.warning("Replay detected: counter=#{counter}, last_seen=#{session.rx_counter}")
          {:error, :replay_detected}
        else
          try do
            # Decrypt with AD (the header)
            plaintext = Decibel.decrypt(session.noise_ref, ciphertext, header)

            # Update rx counter
            session = %{session | rx_counter: counter}
            channel = id_to_channel(channel_id)

            {:ok, session, channel, IO.iodata_to_binary(plaintext)}
          rescue
            e ->
              Logger.warning("Noise decryption failed: #{inspect(e)}")
              {:error, :decryption_failed}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def decrypt(%__MODULE__{state: :handshake}, _framed_ciphertext) do
    {:error, :handshake_not_complete}
  end

  @doc """
  Checks if a message appears to be a handshake message vs encrypted transport.

  Handshake messages don't have our framing header. Transport messages start
  with version byte 0x01, valid channel ID, and flags.

  This is a heuristic - during handshake phase, assume all messages are handshake.
  """
  @spec is_transport_message?(binary()) :: boolean()
  def is_transport_message?(<<@protocol_version, channel, @flags_none, _rest::binary>>)
      when channel in [@channel_api, @channel_media] do
    true
  end

  def is_transport_message?(_), do: false

  # Rekey threshold: rekey after 2^32 messages (configurable)
  @rekey_threshold 4_294_967_296

  @doc """
  Checks if the transmit channel needs rekeying based on message count.
  """
  @spec needs_rekey_tx?(t()) :: boolean()
  def needs_rekey_tx?(%__MODULE__{state: :transport, tx_counter: counter}) do
    counter >= @rekey_threshold
  end

  def needs_rekey_tx?(_), do: false

  @doc """
  Checks if the receive channel needs rekeying based on message count.
  """
  @spec needs_rekey_rx?(t()) :: boolean()
  def needs_rekey_rx?(%__MODULE__{state: :transport, rx_counter: counter}) do
    counter >= @rekey_threshold
  end

  def needs_rekey_rx?(_), do: false

  @doc """
  Returns metrics about the session.
  """
  @spec metrics(t()) :: map()
  def metrics(%__MODULE__{} = session) do
    %{
      session_id: session.session_id,
      state: session.state,
      tx_counter: session.tx_counter,
      rx_counter: session.rx_counter,
      handshake_complete: session.state == :transport
    }
  end

  @doc """
  Rekeys the outbound channel.

  Should be called periodically for forward secrecy.
  """
  @spec rekey_tx(t()) :: {:ok, t()} | {:error, term()}
  def rekey_tx(%__MODULE__{state: :transport} = session) do
    try do
      :ok = Decibel.rekey(session.noise_ref, :out)
      session = %{session | tx_counter: 0}
      {:ok, session}
    rescue
      e ->
        {:error, {:rekey_failed, e}}
    end
  end

  def rekey_tx(%__MODULE__{}), do: {:error, :handshake_not_complete}

  @doc """
  Rekeys the inbound channel.
  """
  @spec rekey_rx(t()) :: {:ok, t()} | {:error, term()}
  def rekey_rx(%__MODULE__{state: :transport} = session) do
    try do
      :ok = Decibel.rekey(session.noise_ref, :in)
      session = %{session | rx_counter: 0}
      {:ok, session}
    rescue
      e ->
        {:error, {:rekey_failed, e}}
    end
  end

  def rekey_rx(%__MODULE__{}), do: {:error, :handshake_not_complete}

  @doc """
  Closes the Noise session and releases resources.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{noise_ref: nil}), do: :ok

  def close(%__MODULE__{noise_ref: ref}) do
    Decibel.close(ref)
  end

  # Private helpers

  defp build_prologue(session_id, instance_id) do
    # prologue = session_id || instance_id || protocol_version
    session_id <> instance_id <> <<@protocol_version>>
  end

  defp build_header(channel_id, counter) do
    <<@protocol_version, channel_id, @flags_none, counter::big-unsigned-64>>
  end

  defp parse_header(<<version, channel_id, flags, counter::big-unsigned-64, ciphertext::binary>>)
       when version == @protocol_version and channel_id in [@channel_api, @channel_media] and
              flags == @flags_none do
    header = <<version, channel_id, flags, counter::big-unsigned-64>>
    {:ok, channel_id, counter, header, ciphertext}
  end

  defp parse_header(<<version, _rest::binary>>) when version != @protocol_version do
    {:error, :unsupported_version}
  end

  defp parse_header(data) when byte_size(data) < @header_size do
    {:error, :message_too_short}
  end

  defp parse_header(_) do
    {:error, :invalid_header}
  end

  defp channel_to_id(:api), do: @channel_api
  defp channel_to_id(:media), do: @channel_media

  defp id_to_channel(@channel_api), do: :api
  defp id_to_channel(@channel_media), do: :media
end
