defmodule Mydia.Crypto.Noise do
  @moduledoc """
  Wrapper module for Noise Protocol cryptographic operations using Decibel library.

  This module provides functions for:
  - Generating Curve25519 keypairs for Noise Protocol
  - Encrypting/decrypting private keys with application secret
  - Basic Noise handshake helpers (Note: Full handshake API is under development)

  ## Security Notes

  - All cryptographic operations use constant-time implementations via Decibel/libsodium
  - Private keys should always be encrypted at rest using encrypt_private_key/2
  - The application secret should be stored securely (e.g., environment variables)

  ## Current Limitations

  The Decibel library returns complex nested data structures for handshake operations
  that require careful handling. Full handshake wrapper implementation is planned for
  a future update.
  """

  @doc """
  Generates a new Curve25519 keypair for Noise Protocol.

  Returns a tuple of `{public_key, private_key}` where both keys are 32-byte binaries.

  ## Examples

      iex> {public_key, private_key} = Mydia.Crypto.Noise.generate_keypair()
      iex> byte_size(public_key)
      32
      iex> byte_size(private_key)
      32

  """
  @spec generate_keypair() :: {binary(), binary()}
  def generate_keypair do
    Decibel.Crypto.generate_keypair(:x25519)
  end

  @doc """
  Encrypts a private key using the application secret.

  Uses authenticated encryption (ChaCha20-Poly1305) to ensure both confidentiality
  and integrity of the private key.

  ## Parameters

  - `private_key` - The 32-byte Curve25519 private key to encrypt
  - `app_secret` - The application secret key (must be 32 bytes)

  ## Returns

  A map containing:
  - `:ciphertext` - The encrypted private key with authentication tag appended
  - `:nonce` - The random nonce used for encryption (as integer)

  ## Examples

      iex> {_public, private} = Mydia.Crypto.Noise.generate_keypair()
      iex> app_secret = :crypto.strong_rand_bytes(32)
      iex> encrypted = Mydia.Crypto.Noise.encrypt_private_key(private, app_secret)
      iex> is_map(encrypted) and Map.has_key?(encrypted, :ciphertext)
      true

  """
  @spec encrypt_private_key(binary(), binary()) :: %{
          ciphertext: binary(),
          nonce: non_neg_integer()
        }
  def encrypt_private_key(private_key, app_secret)
      when byte_size(private_key) == 32 and byte_size(app_secret) == 32 do
    # Generate a random nonce as integer (0 to 2^64-1)
    nonce = :rand.uniform(18_446_744_073_709_551_615)

    # Encrypt using ChaCha20-Poly1305 for authenticated encryption
    # Decibel.Crypto.encrypt returns [ciphertext, tag] for AEAD ciphers
    [ciphertext, tag] =
      Decibel.Crypto.encrypt(:chacha20_poly1305, app_secret, nonce, <<>>, private_key)

    %{
      ciphertext: ciphertext <> tag,
      nonce: nonce
    }
  end

  @doc """
  Decrypts a private key using the application secret.

  ## Parameters

  - `encrypted_data` - Map containing `:ciphertext` and `:nonce` (nonce as integer)
  - `app_secret` - The application secret key (must be 32 bytes)

  ## Returns

  - `{:ok, private_key}` - Successfully decrypted the private key
  - `{:error, :decryption_failed}` - Authentication tag verification failed or invalid ciphertext

  ## Examples

      iex> {_public, private} = Mydia.Crypto.Noise.generate_keypair()
      iex> app_secret = :crypto.strong_rand_bytes(32)
      iex> encrypted = Mydia.Crypto.Noise.encrypt_private_key(private, app_secret)
      iex> {:ok, decrypted} = Mydia.Crypto.Noise.decrypt_private_key(encrypted, app_secret)
      iex> decrypted == private
      true

  """
  @spec decrypt_private_key(%{ciphertext: binary(), nonce: non_neg_integer()}, binary()) ::
          {:ok, binary()} | {:error, :decryption_failed}
  def decrypt_private_key(%{ciphertext: ciphertext_with_tag, nonce: nonce}, app_secret)
      when byte_size(app_secret) == 32 and is_integer(nonce) do
    # ChaCha20-Poly1305 tag is 16 bytes, split it from the ciphertext
    ciphertext_size = byte_size(ciphertext_with_tag) - 16
    <<ciphertext::binary-size(ciphertext_size), tag::binary-size(16)>> = ciphertext_with_tag

    # Decibel.Crypto.decrypt expects [ciphertext, tag] for AEAD ciphers
    # Returns plaintext on success, :error on authentication failure
    case Decibel.Crypto.decrypt(:chacha20_poly1305, app_secret, nonce, <<>>, [ciphertext, tag]) do
      :error -> {:error, :decryption_failed}
      plaintext -> {:ok, plaintext}
    end
  end

  # Note: Handshake functions are under development due to complexity of Decibel's API
  # The functions below are placeholders for future implementation

  @doc false
  def new_handshake(_protocol, _role, _keys \\ %{}) do
    raise "Handshake API under development - use Decibel directly for now"
  end

  @doc false
  def handshake_encrypt(_handshake_ref, _payload \\ <<>>) do
    raise "Handshake API under development - use Decibel directly for now"
  end

  @doc false
  def handshake_decrypt(_handshake_ref, _message) do
    raise "Handshake API under development - use Decibel directly for now"
  end

  @doc false
  def handshake_complete?(_handshake_ref) do
    raise "Handshake API under development - use Decibel directly for now"
  end

  @doc false
  def encrypt(_channel_ref, _plaintext) do
    raise "Handshake API under development - use Decibel directly for now"
  end

  @doc false
  def decrypt(_channel_ref, _ciphertext) do
    raise "Handshake API under development - use Decibel directly for now"
  end

  @doc false
  def get_remote_static_key(_handshake_ref) do
    raise "Handshake API under development - use Decibel directly for now"
  end

  @doc false
  def get_handshake_hash(_handshake_ref) do
    raise "Handshake API under development - use Decibel directly for now"
  end
end
