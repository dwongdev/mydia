defmodule Mydia.Crypto do
  @moduledoc """
  Simplified cryptographic operations using Erlang's `:crypto` module.

  This module provides functions for:
  - X25519 keypair generation for ECDH key exchange
  - Session key derivation via HKDF-SHA256
  - Authenticated encryption/decryption with ChaCha20-Poly1305

  ## Security Notes

  - All cryptographic operations use Erlang's battle-tested `:crypto` module
  - Nonces are randomly generated for each encryption operation
  - Session keys are derived using HKDF with configurable salt and info
  - Always use `derive_session_key/2` after ECDH to get a proper encryption key

  ## Example

      # Generate keypairs for two parties
      {alice_public, alice_private} = Mydia.Crypto.generate_keypair()
      {bob_public, bob_private} = Mydia.Crypto.generate_keypair()

      # Derive session keys (both parties will get the same key)
      alice_session = Mydia.Crypto.derive_session_key(alice_private, bob_public)
      bob_session = Mydia.Crypto.derive_session_key(bob_private, alice_public)

      # Encrypt and decrypt
      encrypted = Mydia.Crypto.encrypt("Hello, World!", alice_session)
      {:ok, "Hello, World!"} = Mydia.Crypto.decrypt(
        encrypted.ciphertext,
        encrypted.nonce,
        encrypted.mac,
        bob_session
      )
  """

  @nonce_size 12
  @key_size 32
  @mac_size 16

  @type keypair :: {public_key :: binary(), private_key :: binary()}
  @type session_key :: binary()
  @type encrypted_data :: %{
          ciphertext: binary(),
          nonce: binary(),
          mac: binary()
        }

  @doc """
  Generates an X25519 keypair for ECDH key exchange.

  Returns a tuple of `{public_key, private_key}` where both keys are 32-byte binaries.

  ## Examples

      iex> {public_key, private_key} = Mydia.Crypto.generate_keypair()
      iex> byte_size(public_key)
      32
      iex> byte_size(private_key)
      32

  """
  @spec generate_keypair() :: keypair()
  def generate_keypair do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :x25519)
    {public_key, private_key}
  end

  @doc """
  Derives a session key from an ECDH shared secret.

  Computes the shared secret using X25519 ECDH, then derives a 32-byte
  session key using HKDF-SHA256.

  ## Parameters

  - `private_key` - Your 32-byte X25519 private key
  - `peer_public_key` - Peer's 32-byte X25519 public key
  - `opts` - Optional keyword list:
    - `:salt` - HKDF salt (default: empty binary)
    - `:info` - HKDF info/context (default: "mydia-session-key")

  ## Returns

  A 32-byte session key suitable for symmetric encryption.

  ## Examples

      iex> {alice_pub, alice_priv} = Mydia.Crypto.generate_keypair()
      iex> {bob_pub, bob_priv} = Mydia.Crypto.generate_keypair()
      iex> alice_key = Mydia.Crypto.derive_session_key(alice_priv, bob_pub)
      iex> bob_key = Mydia.Crypto.derive_session_key(bob_priv, alice_pub)
      iex> alice_key == bob_key
      true

  """
  @spec derive_session_key(binary(), binary(), keyword()) :: session_key()
  def derive_session_key(private_key, peer_public_key, opts \\ [])
      when byte_size(private_key) == 32 and byte_size(peer_public_key) == 32 do
    salt = Keyword.get(opts, :salt, <<>>)
    info = Keyword.get(opts, :info, "mydia-session-key")

    # Compute ECDH shared secret
    shared_secret = :crypto.compute_key(:ecdh, peer_public_key, private_key, :x25519)

    # Debug: Log shared secret fingerprint for cross-platform crypto troubleshooting
    shared_secret_hex = Base.encode16(shared_secret, case: :lower)

    require Logger

    Logger.debug(
      "Crypto.derive_session_key: shared_secret first_8_bytes=#{String.slice(shared_secret_hex, 0, 16)}, salt_size=#{byte_size(salt)}, info=#{inspect(info)}"
    )

    # Derive session key using HKDF-SHA256
    session_key = hkdf_sha256(shared_secret, salt, info, @key_size)

    session_key_hex = Base.encode16(session_key, case: :lower)

    Logger.debug(
      "Crypto.derive_session_key: session_key first_8_bytes=#{String.slice(session_key_hex, 0, 16)}"
    )

    session_key
  end

  @doc """
  Encrypts plaintext using ChaCha20-Poly1305 authenticated encryption.

  Generates a random 12-byte nonce for each encryption operation.

  ## Parameters

  - `plaintext` - The data to encrypt (binary or string)
  - `key` - 32-byte symmetric key (from `derive_session_key/2`)
  - `aad` - Additional Authenticated Data (optional, default: empty)
            This data is authenticated but not encrypted. Use it to bind
            the ciphertext to a specific context (e.g., session_id, message type).

  ## Returns

  A map containing:
  - `:ciphertext` - The encrypted data
  - `:nonce` - The 12-byte random nonce used
  - `:mac` - The 16-byte authentication tag

  ## Examples

      iex> {_pub, priv} = Mydia.Crypto.generate_keypair()
      iex> {peer_pub, _peer_priv} = Mydia.Crypto.generate_keypair()
      iex> key = Mydia.Crypto.derive_session_key(priv, peer_pub)
      iex> encrypted = Mydia.Crypto.encrypt("secret message", key)
      iex> is_binary(encrypted.ciphertext) and byte_size(encrypted.nonce) == 12
      true

      # With AAD for context binding
      iex> encrypted = Mydia.Crypto.encrypt("secret", key, "session123:request")
      iex> byte_size(encrypted.nonce) == 12
      true

  """
  @spec encrypt(binary(), binary(), binary()) :: encrypted_data()
  def encrypt(plaintext, key, aad \\ <<>>) when byte_size(key) == @key_size and is_binary(aad) do
    nonce = :crypto.strong_rand_bytes(@nonce_size)
    encrypt_with_nonce(plaintext, key, nonce, aad)
  end

  @doc """
  Encrypts plaintext with a specified nonce.

  This is primarily for testing purposes to create reproducible test vectors.
  In production, use `encrypt/2` or `encrypt/3` which generates a random nonce.

  ## Parameters

  - `plaintext` - The data to encrypt
  - `key` - 32-byte symmetric key
  - `nonce` - 12-byte nonce
  - `aad` - Additional Authenticated Data (optional)

  ## Returns

  Same as `encrypt/2` - a map with `:ciphertext`, `:nonce`, and `:mac`.
  """
  @spec encrypt_with_nonce(binary(), binary(), binary(), binary()) :: encrypted_data()
  def encrypt_with_nonce(plaintext, key, nonce, aad \\ <<>>)
      when byte_size(key) == @key_size and byte_size(nonce) == @nonce_size and is_binary(aad) do
    {ciphertext, mac} =
      :crypto.crypto_one_time_aead(
        :chacha20_poly1305,
        key,
        nonce,
        plaintext,
        aad,
        _encrypt = true
      )

    %{
      ciphertext: ciphertext,
      nonce: nonce,
      mac: mac
    }
  end

  @doc """
  Decrypts ciphertext using ChaCha20-Poly1305 authenticated encryption.

  Verifies the MAC before returning the plaintext. If AAD was used during
  encryption, the same AAD must be provided for decryption.

  ## Parameters

  - `ciphertext` - The encrypted data
  - `nonce` - The 12-byte nonce used during encryption
  - `mac` - The 16-byte authentication tag
  - `key` - 32-byte symmetric key
  - `aad` - Additional Authenticated Data (optional, default: empty)
            Must match the AAD used during encryption.

  ## Returns

  - `{:ok, plaintext}` - Successfully decrypted and verified
  - `{:error, :decryption_failed}` - MAC verification failed or decryption error

  ## Examples

      iex> {pub, priv} = Mydia.Crypto.generate_keypair()
      iex> {peer_pub, peer_priv} = Mydia.Crypto.generate_keypair()
      iex> alice_key = Mydia.Crypto.derive_session_key(priv, peer_pub)
      iex> bob_key = Mydia.Crypto.derive_session_key(peer_priv, pub)
      iex> encrypted = Mydia.Crypto.encrypt("hello", alice_key)
      iex> Mydia.Crypto.decrypt(encrypted.ciphertext, encrypted.nonce, encrypted.mac, bob_key)
      {:ok, "hello"}

      # With AAD - must match during decryption
      iex> encrypted = Mydia.Crypto.encrypt("hello", alice_key, "context")
      iex> Mydia.Crypto.decrypt(encrypted.ciphertext, encrypted.nonce, encrypted.mac, bob_key, "context")
      {:ok, "hello"}

  """
  @spec decrypt(binary(), binary(), binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, :decryption_failed}
  def decrypt(ciphertext, nonce, mac, key, aad \\ <<>>)

  def decrypt(ciphertext, nonce, mac, key, aad)
      when byte_size(nonce) == @nonce_size and
             byte_size(mac) == @mac_size and
             byte_size(key) == @key_size and
             is_binary(aad) do
    case :crypto.crypto_one_time_aead(
           :chacha20_poly1305,
           key,
           nonce,
           ciphertext,
           aad,
           mac,
           _encrypt = false
         ) do
      :error -> {:error, :decryption_failed}
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
    end
  end

  def decrypt(_ciphertext, _nonce, _mac, _key, _aad) do
    {:error, :decryption_failed}
  end

  # ============================================================================
  # Private Key Storage Functions
  # ============================================================================

  # Old format: 8-byte nonce (zero-padded to 12) + 32-byte ciphertext + 16-byte MAC = 56 bytes
  @legacy_blob_size 56
  # New format: 12-byte nonce + 32-byte ciphertext + 16-byte MAC = 60 bytes
  @new_blob_size 60

  @doc """
  Encrypts a private key for secure storage.

  Uses ChaCha20-Poly1305 with a full 96-bit (12-byte) cryptographically secure
  random nonce for maximum security.

  ## Parameters

  - `private_key` - The 32-byte private key to encrypt
  - `encryption_key` - The 32-byte key used for encryption (e.g., derived from secret_key_base)

  ## Returns

  A binary blob containing: `<<nonce::binary-12, ciphertext::binary-32, mac::binary-16>>`
  Total size: 60 bytes

  ## Examples

      iex> {_pub, priv} = Mydia.Crypto.generate_keypair()
      iex> key = :crypto.strong_rand_bytes(32)
      iex> encrypted = Mydia.Crypto.encrypt_private_key(priv, key)
      iex> byte_size(encrypted) == 60
      true

  """
  @spec encrypt_private_key(binary(), binary()) :: binary()
  def encrypt_private_key(private_key, encryption_key)
      when byte_size(private_key) == 32 and byte_size(encryption_key) == 32 do
    # Generate a full 96-bit (12-byte) cryptographically secure random nonce
    nonce = :crypto.strong_rand_bytes(@nonce_size)

    {ciphertext, mac} =
      :crypto.crypto_one_time_aead(
        :chacha20_poly1305,
        encryption_key,
        nonce,
        private_key,
        _aad = <<>>,
        _encrypt = true
      )

    # Return as a single binary blob: nonce || ciphertext || mac
    nonce <> ciphertext <> mac
  end

  @doc """
  Decrypts a private key that was encrypted with `encrypt_private_key/2`.

  Supports both the new format (96-bit nonce, 60 bytes total) and legacy format
  (64-bit nonce zero-padded to 96-bit, 56 bytes total) for backward compatibility.

  ## Parameters

  - `encrypted_blob` - Binary blob from `encrypt_private_key/2`
  - `encryption_key` - The 32-byte key used for encryption

  ## Returns

  - `{:ok, private_key}` - Successfully decrypted 32-byte private key
  - `{:error, :decryption_failed}` - MAC verification failed or decryption error

  ## Examples

      iex> {_pub, priv} = Mydia.Crypto.generate_keypair()
      iex> key = :crypto.strong_rand_bytes(32)
      iex> encrypted = Mydia.Crypto.encrypt_private_key(priv, key)
      iex> {:ok, decrypted} = Mydia.Crypto.decrypt_private_key(encrypted, key)
      iex> decrypted == priv
      true

  """
  @spec decrypt_private_key(binary(), binary()) ::
          {:ok, binary()} | {:error, :decryption_failed}
  def decrypt_private_key(encrypted_blob, encryption_key)
      when is_binary(encrypted_blob) and byte_size(encryption_key) == 32 do
    case byte_size(encrypted_blob) do
      @new_blob_size ->
        # New format: full 96-bit nonce
        <<nonce::binary-size(@nonce_size), ciphertext::binary-32, mac::binary-size(@mac_size)>> =
          encrypted_blob

        decrypt_with_nonce(ciphertext, nonce, mac, encryption_key)

      @legacy_blob_size ->
        # Legacy format: 64-bit nonce zero-padded to 96-bit
        <<nonce_64::binary-8, ciphertext::binary-32, mac::binary-size(@mac_size)>> =
          encrypted_blob

        nonce_padded = nonce_64 <> <<0::32>>
        decrypt_with_nonce(ciphertext, nonce_padded, mac, encryption_key)

      _ ->
        {:error, :decryption_failed}
    end
  end

  # Legacy format support: decrypt using map with integer nonce
  def decrypt_private_key(%{ciphertext: ciphertext_with_mac, nonce: nonce_int}, encryption_key)
      when is_integer(nonce_int) and byte_size(encryption_key) == 32 do
    # Ciphertext includes the 16-byte MAC at the end
    ciphertext_len = byte_size(ciphertext_with_mac) - @mac_size
    <<ciphertext::binary-size(ciphertext_len), mac::binary-size(@mac_size)>> = ciphertext_with_mac

    # Convert integer nonce to padded binary
    nonce_bin = <<nonce_int::64>>
    nonce_padded = nonce_bin <> <<0::32>>

    decrypt_with_nonce(ciphertext, nonce_padded, mac, encryption_key)
  end

  def decrypt_private_key(_encrypted_data, _encryption_key) do
    {:error, :decryption_failed}
  end

  # Helper function for decryption
  defp decrypt_with_nonce(ciphertext, nonce, mac, encryption_key) do
    case :crypto.crypto_one_time_aead(
           :chacha20_poly1305,
           encryption_key,
           nonce,
           ciphertext,
           _aad = <<>>,
           mac,
           _encrypt = false
         ) do
      :error -> {:error, :decryption_failed}
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
    end
  end

  # Private helper functions

  @doc false
  @spec hkdf_sha256(binary(), binary(), binary(), pos_integer()) :: binary()
  defp hkdf_sha256(input_key_material, salt, info, length)
       when is_binary(input_key_material) and is_binary(info) and length > 0 do
    # HKDF Extract: PRK = HMAC-Hash(salt, IKM)
    effective_salt = if salt == <<>>, do: :binary.copy(<<0>>, 32), else: salt
    prk = :crypto.mac(:hmac, :sha256, effective_salt, input_key_material)

    # HKDF Expand: OKM = T(1) || T(2) || ... where T(i) = HMAC-Hash(PRK, T(i-1) || info || i)
    hkdf_expand(prk, info, length)
  end

  defp hkdf_expand(prk, info, length) do
    hash_len = 32
    n = ceil(length / hash_len)

    {okm, _} =
      Enum.reduce(1..n, {<<>>, <<>>}, fn i, {acc, prev} ->
        t = :crypto.mac(:hmac, :sha256, prk, prev <> info <> <<i::8>>)
        {acc <> t, t}
      end)

    binary_part(okm, 0, length)
  end
end
