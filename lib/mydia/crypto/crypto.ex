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

    # Derive session key using HKDF-SHA256
    hkdf_sha256(shared_secret, salt, info, @key_size)
  end

  @doc """
  Encrypts plaintext using ChaCha20-Poly1305 authenticated encryption.

  Generates a random 12-byte nonce for each encryption operation.

  ## Parameters

  - `plaintext` - The data to encrypt (binary or string)
  - `key` - 32-byte symmetric key (from `derive_session_key/2`)

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

  """
  @spec encrypt(binary(), binary()) :: encrypted_data()
  def encrypt(plaintext, key) when byte_size(key) == @key_size do
    nonce = :crypto.strong_rand_bytes(@nonce_size)

    {ciphertext, mac} =
      :crypto.crypto_one_time_aead(
        :chacha20_poly1305,
        key,
        nonce,
        plaintext,
        _aad = <<>>,
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

  Verifies the MAC before returning the plaintext.

  ## Parameters

  - `ciphertext` - The encrypted data
  - `nonce` - The 12-byte nonce used during encryption
  - `mac` - The 16-byte authentication tag
  - `key` - 32-byte symmetric key

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

  """
  @spec decrypt(binary(), binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, :decryption_failed}
  def decrypt(ciphertext, nonce, mac, key)
      when byte_size(nonce) == @nonce_size and
             byte_size(mac) == @mac_size and
             byte_size(key) == @key_size do
    case :crypto.crypto_one_time_aead(
           :chacha20_poly1305,
           key,
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

  def decrypt(_ciphertext, _nonce, _mac, _key) do
    {:error, :decryption_failed}
  end

  # ============================================================================
  # Private Key Storage Functions
  # ============================================================================

  @doc """
  Encrypts a private key for secure storage.

  Uses ChaCha20-Poly1305 with a 64-bit random nonce. This format is designed
  for storing private keys in the database with the nonce as an integer.

  ## Parameters

  - `private_key` - The 32-byte private key to encrypt
  - `encryption_key` - The 32-byte key used for encryption (e.g., derived from secret_key_base)

  ## Returns

  A map containing:
  - `:ciphertext` - The encrypted private key with MAC appended
  - `:nonce` - A 64-bit integer nonce

  ## Storage Format

  The result is typically stored as: `<<nonce::64, ciphertext::binary>>`

  ## Examples

      iex> {_pub, priv} = Mydia.Crypto.generate_keypair()
      iex> key = :crypto.strong_rand_bytes(32)
      iex> encrypted = Mydia.Crypto.encrypt_private_key(priv, key)
      iex> is_integer(encrypted.nonce) and is_binary(encrypted.ciphertext)
      true

  """
  @spec encrypt_private_key(binary(), binary()) :: %{ciphertext: binary(), nonce: integer()}
  def encrypt_private_key(private_key, encryption_key)
      when byte_size(private_key) == 32 and byte_size(encryption_key) == 32 do
    # Generate a random 64-bit nonce (as integer for storage compatibility)
    nonce_int = :rand.uniform(0xFFFFFFFFFFFFFFFF)
    # Convert to 8-byte binary for crypto operations
    nonce_bin = <<nonce_int::64>>

    # Encrypt using ChaCha20-Poly1305
    # Note: ChaCha20-Poly1305 normally uses 12-byte nonce, but we pad with zeros
    nonce_padded = nonce_bin <> <<0::32>>

    {ciphertext, mac} =
      :crypto.crypto_one_time_aead(
        :chacha20_poly1305,
        encryption_key,
        nonce_padded,
        private_key,
        _aad = <<>>,
        _encrypt = true
      )

    %{
      ciphertext: ciphertext <> mac,
      nonce: nonce_int
    }
  end

  @doc """
  Decrypts a private key that was encrypted with `encrypt_private_key/2`.

  ## Parameters

  - `encrypted_data` - Map with `:ciphertext` and `:nonce` (as integer)
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
  @spec decrypt_private_key(%{ciphertext: binary(), nonce: integer()}, binary()) ::
          {:ok, binary()} | {:error, :decryption_failed}
  def decrypt_private_key(%{ciphertext: ciphertext_with_mac, nonce: nonce_int}, encryption_key)
      when is_integer(nonce_int) and byte_size(encryption_key) == 32 do
    # Ciphertext includes the 16-byte MAC at the end
    ciphertext_len = byte_size(ciphertext_with_mac) - @mac_size
    <<ciphertext::binary-size(ciphertext_len), mac::binary-size(@mac_size)>> = ciphertext_with_mac

    # Convert integer nonce to padded binary
    nonce_bin = <<nonce_int::64>>
    nonce_padded = nonce_bin <> <<0::32>>

    case :crypto.crypto_one_time_aead(
           :chacha20_poly1305,
           encryption_key,
           nonce_padded,
           ciphertext,
           _aad = <<>>,
           mac,
           _encrypt = false
         ) do
      :error -> {:error, :decryption_failed}
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
    end
  end

  def decrypt_private_key(_encrypted_data, _encryption_key) do
    {:error, :decryption_failed}
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
